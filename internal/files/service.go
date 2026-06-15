// Package files implements the FilesService Connect handler and the
// raw-bytes HTTP endpoint that signed URLs point at.
//
// Architectural split:
//
//   - Connect-RPC for upload (client-streaming) + metadata (ListFiles,
//     GetFileURL). The streaming protocol is the right shape for a
//     bounded-size byte upload — backpressure works, the server can
//     reject early on bad headers, and Connect handles framing.
//   - Raw HTTP for download. A signed URL goes straight into the
//     client's image loader without re-implementing Connect framing
//     in JavaScript / Swift on the receiver side. HMAC-signed token
//     (see urltoken.go) authorizes the bearer.
package files

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"google.golang.org/protobuf/types/known/timestamppb"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/gen/reeve/v1/reevev1connect"
	"github.com/jdpedrie/reeve/internal/auth"
	"github.com/jdpedrie/reeve/internal/storage"
	"github.com/jdpedrie/reeve/internal/store"
)

// MaxUploadSize is the hard cap on a single upload. Enforced server-
// side at both the header step (declared size) and the bytes step
// (running tally) so a misbehaving client can't slip past the
// declared-size check.
const MaxUploadSize = 50 * 1024 * 1024 // 50 MB

// Service implements reevev1connect.FilesServiceHandler.
type Service struct {
	reevev1connect.UnimplementedFilesServiceHandler

	queries    *store.Queries
	store      storage.Storage
	signingKey []byte
	// baseURL is the externally-reachable origin of this reeved
	// (e.g. "https://reeve.example.com"). Used to build absolute
	// URLs in GetFileURL responses. Empty falls back to relative
	// paths — clients prepend their own base.
	baseURL string
	// nowFn lets tests freeze time for token-expiry assertions.
	// Defaults to time.Now.
	nowFn func() time.Time
}

// NewService constructs a Service. baseURL may be empty (clients
// will treat the returned URL as relative); signingKey must be a
// non-empty byte slice — derive via files.DeriveSigningKey from the
// crypto master key.
func NewService(queries *store.Queries, st storage.Storage, signingKey []byte, baseURL string) *Service {
	return &Service{
		queries:    queries,
		store:      st,
		signingKey: signingKey,
		baseURL:    baseURL,
		nowFn:      time.Now,
	}
}

// UploadFile is the client-streaming handler. Receives a Header
// message followed by zero or more Chunk messages; computes the
// SHA-256, validates the size cap, hands the bytes to Storage, and
// writes the `files` row (idempotent on user+sha256).
func (s *Service) UploadFile(ctx context.Context, stream *connect.ClientStream[reevev1.UploadFileRequest]) (*connect.Response[reevev1.UploadFileResponse], error) {
	user := auth.MustFromContext(ctx)

	var header *reevev1.UploadFileHeader
	var buf bytes.Buffer
	hasher := sha256.New()
	var received int64

	for stream.Receive() {
		msg := stream.Msg()
		switch body := msg.GetBody().(type) {
		case *reevev1.UploadFileRequest_Header:
			if header != nil {
				return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("multiple headers"))
			}
			header = body.Header
			if header.GetMimeType() == "" {
				return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("mime_type required"))
			}
			if header.GetSizeBytes() <= 0 {
				return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("size_bytes required"))
			}
			if header.GetSizeBytes() > MaxUploadSize {
				return nil, connect.NewError(connect.CodeInvalidArgument,
					fmt.Errorf("upload exceeds %d byte cap", MaxUploadSize))
			}
		case *reevev1.UploadFileRequest_Chunk:
			if header == nil {
				return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("chunk before header"))
			}
			chunk := body.Chunk
			received += int64(len(chunk))
			if received > MaxUploadSize {
				return nil, connect.NewError(connect.CodeInvalidArgument,
					fmt.Errorf("upload exceeds %d byte cap", MaxUploadSize))
			}
			if received > header.GetSizeBytes() {
				return nil, connect.NewError(connect.CodeInvalidArgument,
					errors.New("upload exceeds declared size"))
			}
			if _, err := buf.Write(chunk); err != nil {
				return nil, connect.NewError(connect.CodeInternal, err)
			}
			if _, err := hasher.Write(chunk); err != nil {
				return nil, connect.NewError(connect.CodeInternal, err)
			}
		}
	}
	if err := stream.Err(); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if header == nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("missing header"))
	}
	if received != header.GetSizeBytes() {
		return nil, connect.NewError(connect.CodeInvalidArgument,
			fmt.Errorf("declared %d bytes, got %d", header.GetSizeBytes(), received))
	}

	sum := hex.EncodeToString(hasher.Sum(nil))

	// Storage first, DB row second. If Storage fails, no row exists —
	// safe. If the DB write fails after the blob lands, we have a
	// dangling file with no `files` row pointing at it; that's wasted
	// disk but not a correctness issue, and the next re-upload with
	// the same bytes will reuse the existing blob anyway.
	if err := s.store.Put(ctx, user.ID, sum, header.GetMimeType(), bytes.NewReader(buf.Bytes())); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("storage put: %w", err))
	}

	id := uuid.New()
	row, err := s.queries.CreateFile(ctx, store.CreateFileParams{
		ID:               id,
		UserID:           user.ID,
		Sha256:           sum,
		MimeType:         header.GetMimeType(),
		SizeBytes:        received,
		OriginalFilename: header.OriginalFilename,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("create file row: %w", err))
	}

	return connect.NewResponse(&reevev1.UploadFileResponse{
		FileId:           row.ID.String(),
		Sha256:           row.Sha256,
		MimeType:         row.MimeType,
		SizeBytes:        row.SizeBytes,
		OriginalFilename: row.OriginalFilename,
		CreatedAt:        timestamppb.New(row.CreatedAt),
	}), nil
}

// Store persists raw bytes as a file owned by userID and returns the new
// file's id. It is the non-streaming counterpart to UploadFile, for callers
// that already hold the whole blob in memory (the web client, which cannot
// drive the client-streaming RPC from a browser). Same size cap and the same
// storage-first, row-second ordering as UploadFile.
func (s *Service) Store(ctx context.Context, userID uuid.UUID, mime, filename string, data []byte) (string, error) {
	if mime == "" {
		return "", fmt.Errorf("mime_type required")
	}
	if int64(len(data)) > MaxUploadSize {
		return "", fmt.Errorf("upload exceeds %d byte cap", MaxUploadSize)
	}
	h := sha256.Sum256(data)
	sum := hex.EncodeToString(h[:])
	if err := s.store.Put(ctx, userID, sum, mime, bytes.NewReader(data)); err != nil {
		return "", fmt.Errorf("storage put: %w", err)
	}
	var fn *string
	if filename != "" {
		fn = &filename
	}
	row, err := s.queries.CreateFile(ctx, store.CreateFileParams{
		ID:               uuid.New(),
		UserID:           userID,
		Sha256:           sum,
		MimeType:         mime,
		SizeBytes:        int64(len(data)),
		OriginalFilename: fn,
	})
	if err != nil {
		return "", fmt.Errorf("create file row: %w", err)
	}
	return row.ID.String(), nil
}

// GetFileURL mints a short-lived signed URL for the given file. The
// caller must own the file.
func (s *Service) GetFileURL(ctx context.Context, req *connect.Request[reevev1.GetFileURLRequest]) (*connect.Response[reevev1.GetFileURLResponse], error) {
	user := auth.MustFromContext(ctx)
	fileID, err := uuid.Parse(req.Msg.GetFileId())
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid file_id: %w", err))
	}
	row, err := s.queries.GetFile(ctx, fileID)
	if err != nil {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("file not found"))
	}
	if row.UserID != user.ID {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("file not found"))
	}
	expires := s.nowFn().Add(SignedURLTTL)
	token := SignToken(s.signingKey, fileID, user.ID, expires)
	url := fmt.Sprintf("%s/files/%s?token=%s", s.baseURL, fileID.String(), token)
	return connect.NewResponse(&reevev1.GetFileURLResponse{
		Url:       url,
		ExpiresAt: timestamppb.New(expires),
	}), nil
}

// ListFiles returns the caller's recent files.
func (s *Service) ListFiles(ctx context.Context, req *connect.Request[reevev1.ListFilesRequest]) (*connect.Response[reevev1.ListFilesResponse], error) {
	user := auth.MustFromContext(ctx)
	limit := int32(50)
	if v := req.Msg.Limit; v != nil && *v > 0 {
		limit = *v
	}
	if limit > 500 {
		limit = 500
	}
	rows, err := s.queries.ListFilesForUser(ctx, store.ListFilesForUserParams{
		UserID: user.ID,
		Limit:  limit,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*reevev1.FileMeta, 0, len(rows))
	for _, r := range rows {
		out = append(out, &reevev1.FileMeta{
			Id:               r.ID.String(),
			Sha256:           r.Sha256,
			MimeType:         r.MimeType,
			SizeBytes:        r.SizeBytes,
			OriginalFilename: r.OriginalFilename,
			CreatedAt:        timestamppb.New(r.CreatedAt),
		})
	}
	return connect.NewResponse(&reevev1.ListFilesResponse{Files: out}), nil
}

// BytesHandler serves the raw bytes for a signed URL. Mount at
// `GET /files/{id}` on the reeved mux. Reads + verifies the token,
// loads the file row, streams the storage object through to the
// response. No Connect framing — straight HTTP so a system image
// loader can fetch it.
func (s *Service) BytesHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		// Path: /files/{id} — Go 1.22+ pattern routes embed the id;
		// PathValue extracts it without a third-party router.
		fileID, err := uuid.Parse(r.PathValue("id"))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		token := r.URL.Query().Get("token")
		if token == "" {
			http.NotFound(w, r)
			return
		}
		userID, err := VerifyToken(s.signingKey, token, fileID, s.nowFn())
		if err != nil {
			// 404 not 401 — surfacing "invalid token" lets attackers
			// probe for the difference between "id exists but token
			// bad" and "id doesn't exist". Both look identical.
			http.NotFound(w, r)
			return
		}
		row, err := s.queries.GetFile(r.Context(), fileID)
		if err != nil || row.UserID != userID {
			http.NotFound(w, r)
			return
		}
		reader, err := s.store.Get(r.Context(), row.UserID, row.Sha256)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		defer reader.Close()
		w.Header().Set("Content-Type", row.MimeType)
		w.Header().Set("Content-Length", fmt.Sprintf("%d", row.SizeBytes))
		// Cache aggressively client-side: signed URL is short-lived
		// and content-addressed, so the bytes are immutable for the
		// life of this URL.
		w.Header().Set("Cache-Control", "private, max-age=30, immutable")
		if r.Method == http.MethodHead {
			return
		}
		_, _ = io.Copy(w, reader)
	}
}
