package profiles

import "testing"

func TestParseSeed_NoFrontmatter(t *testing.T) {
	doc, err := parseSeed("plain body\nsecond line")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if doc.SystemMessage != "plain body\nsecond line" {
		t.Errorf("system_message: %q", doc.SystemMessage)
	}
	if doc.WelcomeMessage != "" {
		t.Errorf("welcome_message should be empty: %q", doc.WelcomeMessage)
	}
}

func TestParseSeed_FrontmatterScalar(t *testing.T) {
	in := "---\nwelcome_message: Hi there\n---\nbody"
	doc, err := parseSeed(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if doc.WelcomeMessage != "Hi there" {
		t.Errorf("welcome_message: %q", doc.WelcomeMessage)
	}
	if doc.SystemMessage != "body" {
		t.Errorf("system_message: %q", doc.SystemMessage)
	}
}

func TestParseSeed_FrontmatterBlockScalar(t *testing.T) {
	in := "---\nwelcome_message: |\n  Hello!\n  Multi-line is fine.\n---\nbody here"
	doc, err := parseSeed(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if doc.WelcomeMessage != "Hello!\nMulti-line is fine." {
		t.Errorf("welcome_message: %q", doc.WelcomeMessage)
	}
	if doc.SystemMessage != "body here" {
		t.Errorf("system_message: %q", doc.SystemMessage)
	}
}

func TestParseSeed_MissingCloseDelimiter(t *testing.T) {
	in := "---\nwelcome_message: hi\nbody but no close"
	_, err := parseSeed(in)
	if err == nil {
		t.Fatal("expected error for missing close delimiter")
	}
}

func TestParseSeed_UnknownKeysIgnored(t *testing.T) {
	in := "---\nunknown_key: value\nwelcome_message: hi\n---\nbody"
	doc, err := parseSeed(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if doc.WelcomeMessage != "hi" {
		t.Errorf("welcome_message: %q", doc.WelcomeMessage)
	}
}

func TestParseSeed_BlockScalarWithBlankLines(t *testing.T) {
	in := "---\nwelcome_message: |\n  Paragraph one.\n\n  Paragraph two.\n---\n"
	doc, err := parseSeed(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	want := "Paragraph one.\n\nParagraph two."
	if doc.WelcomeMessage != want {
		t.Errorf("welcome_message: got %q want %q", doc.WelcomeMessage, want)
	}
}
