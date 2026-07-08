package speechsvc

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/speech"
	"github.com/jdpedrie/psmith/internal/store"
)

// Per-kind synthesis prices, USD per character — the constraints-table
// pattern: hand-maintained, revisit when a vendor reprices. The
// openai-compatible price applies only against the vendor's own
// endpoint; a custom base URL means self-hosted, which is free and
// must not be billed as OpenAI.
var perCharUSD = map[string]float64{
	"grok":              4.20 / 1_000_000,
	"openai-compatible": 15.0 / 1_000_000,
}

// ttsRequest is the POST /tts body.
type ttsRequest struct {
	MessageID string `json:"message_id"`
}

// TTSHandler streams synthesized speech for one owned message: bearer
// auth, ownership through message → context → conversation, normalize,
// segment, drive the configured synthesizer, and chunk PCM back with
// flushes so playback starts on the first frame. Audio is never
// persisted — this response is the only copy the server ever holds.
//
// The response is audio/pcm (s16le mono) with the sample rate and
// normalizer version in headers; the client replay cache keys on the
// latter. apple_local configs are refused with 412 — that kind is
// synthesized on-device and the client shouldn't have called.
func (s *Service) TTSHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user, err := auth.AuthenticateBearer(r.Context(), s.queries, r.Header.Get("Authorization"))
		if err != nil {
			if errors.Is(err, auth.ErrUnauthenticated) {
				httpError(w, http.StatusUnauthorized, "unauthenticated")
				return
			}
			httpError(w, http.StatusInternalServerError, "auth failed")
			return
		}

		var body ttsRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			httpError(w, http.StatusBadRequest, "invalid JSON body")
			return
		}
		msgID, err := uuid.Parse(body.MessageID)
		if err != nil {
			httpError(w, http.StatusBadRequest, "invalid message_id")
			return
		}

		msg, err := s.ownedMessage(r, msgID, user.ID)
		if err != nil {
			httpError(w, http.StatusNotFound, "message not found")
			return
		}

		synth, kind, req, err := s.BuildForUser(r.Context(), user.ID)
		if err != nil {
			httpError(w, http.StatusBadGateway, err.Error())
			return
		}
		if kind == KindAppleLocal {
			httpError(w, http.StatusPreconditionFailed, "speech kind apple_local is synthesized on-device")
			return
		}

		normalized := speech.NormalizeMarkdown(msg.Content)
		segments := speech.SegmentAll(normalized)
		if len(segments) == 0 {
			httpError(w, http.StatusUnprocessableEntity, "message has no speakable text")
			return
		}

		in := make(chan string, len(segments))
		for _, seg := range segments {
			in <- seg
		}
		close(in)
		frames, errs := synth.Synthesize(r.Context(), req, in)

		w.Header().Set("Content-Type", "audio/pcm")
		w.Header().Set("X-Speech-Sample-Rate", strconv.Itoa(speech.SampleRate))
		w.Header().Set("X-Speech-Normalizer", strconv.Itoa(speech.NormalizerVersion))
		flusher, _ := w.(http.Flusher)

		wrote := false
		for f := range frames {
			if _, err := w.Write(f.PCM); err != nil {
				return // client went away
			}
			wrote = true
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err := <-errs; err != nil {
			if !wrote {
				httpError(w, http.StatusBadGateway, err.Error())
				return
			}
			// Mid-stream failure: the response is already committed as
			// audio. Log and truncate; the client retries if it cares.
			s.logger.Warn("tts: synthesis failed mid-stream", "err", err, "message_id", msgID)
			return
		}

		s.recordCost(r, user.ID, msgID, kind, normalized)
	}
}

// ownedMessage resolves a message through its context to the owning
// conversation, NotFound-masking cross-user access like the RPCs do.
func (s *Service) ownedMessage(r *http.Request, msgID, userID uuid.UUID) (store.Message, error) {
	msg, err := s.queries.GetMessageByID(r.Context(), msgID)
	if err != nil {
		return store.Message{}, err
	}
	cx, err := s.queries.GetContextByID(r.Context(), msg.ContextID)
	if err != nil {
		return store.Message{}, err
	}
	conv, err := s.queries.GetConversationByID(r.Context(), cx.ConversationID)
	if err != nil {
		return store.Message{}, err
	}
	if conv.UserID != userID {
		return store.Message{}, errors.New("not owner")
	}
	return msg, nil
}

// recordCost writes a cost_events row for the synthesis. Only possible
// when the config references a chat provider row (cost_events.provider_id
// is a foreign key); standalone-key and self-hosted configs skip the
// ledger — documented in docs/design/speech.md. Best-effort: a ledger
// failure never fails the audio the user already received.
func (s *Service) recordCost(r *http.Request, userID, msgID uuid.UUID, kind, normalized string) {
	price := perCharUSD[kind]
	if price <= 0 {
		return
	}
	row, err := s.queries.GetUserTTSConfig(r.Context(), userID)
	if err != nil || row.ProviderRef == nil {
		return // no provider row to attribute spend to
	}
	var ns nonSecretConfig
	_ = json.Unmarshal(row.Config, &ns)
	if kind == "openai-compatible" && ns.BaseURL != "" {
		return // self-hosted: free
	}
	amount := price * float64(len(normalized))
	if err := s.queries.InsertCostEvent(r.Context(), store.InsertCostEventParams{
		ProviderID: *row.ProviderRef,
		ModelID:    fmt.Sprintf("tts:%s", kind),
		AmountUsd:  floatToNumeric(amount),
		MessageID:  &msgID,
	}); err != nil {
		s.logger.Warn("tts: cost record failed", "err", err)
	}
}

func httpError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// floatToNumeric parses a float into pgtype.Numeric via string
// round-trip — same approach as the stream supervisor's cost writes.
func floatToNumeric(v float64) pgtype.Numeric {
	var n pgtype.Numeric
	if err := n.Scan(strconv.FormatFloat(v, 'f', 8, 64)); err != nil {
		return pgtype.Numeric{}
	}
	return n
}
