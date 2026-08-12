package conversations

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/server/providers"
	"github.com/jdpedrie/psmith/server/store"
)

// uploaderDriver is a stateless driver that also accepts uploads.
type uploaderDriver struct {
	fakeStatelessDriver
	uploads   int
	failWith  error
	supported func(string) bool
	expiry    time.Time
}

func (u *uploaderDriver) UploadFile(_ context.Context, mime, _ string, data []byte) (string, time.Time, error) {
	u.uploads++
	if u.failWith != nil {
		return "", time.Time{}, u.failWith
	}
	return "files/" + mime + "-" + string(rune('a'+u.uploads)), u.expiry, nil
}

func (u *uploaderDriver) SupportsFileReference(mime string) bool {
	if u.supported != nil {
		return u.supported(mime)
	}
	return true
}

func att(sha, mime string, data []byte) providers.Attachment {
	return providers.Attachment{
		Kind: providers.AttachmentImage, MimeType: mime,
		Filename: "x.png", Data: data, SHA256: sha,
	}
}

func msgsWith(as ...providers.Attachment) []providers.WireMessage {
	return []providers.WireMessage{{Role: "user", Content: "look", Attachments: as}}
}

// The point of the whole feature: bytes cross once, and later turns carry a
// reference instead.
func TestAttachProviderFiles_UploadsOnceThenReferences(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")
	drv := &uploaderDriver{}

	first := msgsWith(att("sha-1", "image/png", []byte("BYTES")))
	svc.attachProviderFiles(context.Background(), drv, f.provider, f.user.ID, first)

	got := first[0].Attachments[0]
	if got.ProviderFileID == "" {
		t.Fatal("expected a provider reference after upload")
	}
	if len(got.Data) != 0 {
		t.Error("bytes must be dropped once referenced; sending both defeats the purpose")
	}
	if drv.uploads != 1 {
		t.Errorf("expected 1 upload, got %d", drv.uploads)
	}

	// A later turn re-inlines the same blob from history; it must hit the
	// recorded row rather than upload again.
	second := msgsWith(att("sha-1", "image/png", []byte("BYTES")))
	svc.attachProviderFiles(context.Background(), drv, f.provider, f.user.ID, second)
	if drv.uploads != 1 {
		t.Errorf("second send re-uploaded: %d uploads total", drv.uploads)
	}
	if second[0].Attachments[0].ProviderFileID != got.ProviderFileID {
		t.Error("second send should reuse the recorded reference")
	}
}

// The same image quoted across several turns is one blob, not one upload per
// mention.
func TestAttachProviderFiles_DeduplicatesWithinOnePrefix(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")
	drv := &uploaderDriver{}

	msgs := []providers.WireMessage{
		{Role: "user", Attachments: []providers.Attachment{att("same", "image/png", []byte("B"))}},
		{Role: "user", Attachments: []providers.Attachment{att("same", "image/png", []byte("B"))}},
		{Role: "user", Attachments: []providers.Attachment{att("same", "image/png", []byte("B"))}},
	}
	svc.attachProviderFiles(context.Background(), drv, f.provider, f.user.ID, msgs)
	if drv.uploads != 1 {
		t.Errorf("expected 1 upload for 3 mentions of one blob, got %d", drv.uploads)
	}
	for i, m := range msgs {
		if m.Attachments[0].ProviderFileID == "" {
			t.Errorf("message %d did not get the reference", i)
		}
	}
}

// Every failure must degrade to inline bytes. This is the property that makes
// the feature safe to turn on: an outage costs bandwidth, never a turn.
func TestAttachProviderFiles_FallsBackToInline(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	cases := map[string]providers.Provider{
		"driver cannot upload at all": &fakeStatelessDriver{},
		"upload errors":               &uploaderDriver{failWith: errors.New("503 files api down")},
		"mime type unsupported":       &uploaderDriver{supported: func(string) bool { return false }},
	}
	for name, drv := range cases {
		t.Run(name, func(t *testing.T) {
			msgs := msgsWith(att("sha-x", "image/png", []byte("BYTES")))
			svc.attachProviderFiles(context.Background(), drv, f.provider, f.user.ID, msgs)
			got := msgs[0].Attachments[0]
			if got.ProviderFileID != "" {
				t.Errorf("expected no reference, got %q", got.ProviderFileID)
			}
			if string(got.Data) != "BYTES" {
				t.Errorf("bytes must survive so the driver can inline them, got %q", got.Data)
			}
		})
	}
}

// An expired reference must not be served; the row is re-uploaded instead.
func TestAttachProviderFiles_IgnoresExpiredReferences(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	past := time.Now().Add(-time.Hour)
	if _, err := q.UpsertProviderFile(context.Background(), store.UpsertProviderFileParams{
		UserModelProviderID: f.provider.ID,
		Sha256:              "sha-old",
		UserID:              f.user.ID,
		ProviderFileID:      "files/expired",
		MimeType:            "image/png",
		SizeBytes:           5,
		ExpiresAt:           &past,
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	drv := &uploaderDriver{}
	msgs := msgsWith(att("sha-old", "image/png", []byte("BYTES")))
	svc.attachProviderFiles(context.Background(), drv, f.provider, f.user.ID, msgs)

	if drv.uploads != 1 {
		t.Errorf("an expired reference should trigger a fresh upload, uploads=%d", drv.uploads)
	}
	if got := msgs[0].Attachments[0].ProviderFileID; got == "files/expired" {
		t.Error("served an expired reference")
	}
}

// An attachment with no content hash cannot be keyed, so it must be left alone
// rather than uploaded under a blank key.
func TestAttachProviderFiles_SkipsUnhashedAttachments(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")
	drv := &uploaderDriver{}

	msgs := msgsWith(att("", "image/png", []byte("BYTES")))
	svc.attachProviderFiles(context.Background(), drv, f.provider, f.user.ID, msgs)
	if drv.uploads != 0 {
		t.Errorf("an unhashed attachment must not be uploaded, uploads=%d", drv.uploads)
	}
	if string(msgs[0].Attachments[0].Data) != "BYTES" {
		t.Error("bytes must survive for inlining")
	}
}

// References are per provider row, since an upload lives behind one account's
// credentials and is invisible to another.
func TestAttachProviderFiles_ReferencesAreNotSharedAcrossProviders(t *testing.T) {
	t.Parallel()
	svc, q, _ := newFullSvc(t)
	f := seedAnthropicSendable(t, q, "http://127.0.0.1:1")

	other := store.UserModelProvider{}
	{
		id, _ := uuid.NewV7()
		row, err := q.CreateUserModelProvider(context.Background(), store.CreateUserModelProviderParams{
			ID: id, UserID: f.user.ID, Type: "anthropic", Label: "second",
			ConfigEncrypted: []byte(`{"api_key":"y"}`),
		})
		if err != nil {
			t.Fatalf("second provider: %v", err)
		}
		other = row
	}

	drv := &uploaderDriver{}
	a := msgsWith(att("shared", "image/png", []byte("B")))
	svc.attachProviderFiles(context.Background(), drv, f.provider, f.user.ID, a)

	b := msgsWith(att("shared", "image/png", []byte("B")))
	svc.attachProviderFiles(context.Background(), drv, other, f.user.ID, b)

	if drv.uploads != 2 {
		t.Errorf("each provider needs its own upload, got %d", drv.uploads)
	}
}
