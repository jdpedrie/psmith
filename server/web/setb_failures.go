package web

import (
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// A failed Test reads the way the apps word it: a red line saying what
// went wrong in plain words, and the service's own error under it in
// small mono type, for whoever has to fix it. The raw error alone read as
// `post: Post "http://…": dial tcp …: connection refused`.

// testFailed is a failed integration Test: "Test failed after 12 ms." and,
// when the error is one we recognize, what it means.
func testFailed(latencyMs int64, raw, service string) *testVM {
	lead := "Test failed."
	if latencyMs > 0 {
		lead = "Test failed after " + strconv.FormatInt(latencyMs, 10) + " ms."
	}
	return failedLine(lead, raw, service)
}

// connectFailed is a failed MCP server test, as the Mac words it.
func connectFailed(raw string) *testVM {
	return failedLine("Couldn't connect.", raw, "The server")
}

func failedLine(lead, raw, service string) *testVM {
	raw = strings.TrimSpace(raw)
	t := &testVM{Message: lead, Detail: raw}
	if why := failureReason(raw, service); why != "" {
		t.Message += " " + why
	} else if raw == "" {
		t.Message += " No reason given."
	}
	return t
}

var (
	quotedURL  = regexp.MustCompile(`"(https?://[^"\s]+)"`)
	statusCode = regexp.MustCompile(`\b(?:status|HTTP|returned) (\d{3})\b`)
	exitStatus = regexp.MustCompile(`exit status (\d+)`)
)

// failureReason words a raw test error in a sentence, or "" when it isn't
// one we recognize. service names who answered ("Langfuse").
func failureReason(raw, service string) string {
	low := strings.ToLower(raw)
	host := "that address"
	if m := quotedURL.FindStringSubmatch(raw); m != nil {
		if u, err := url.Parse(m[1]); err == nil && u.Host != "" {
			host = u.Host
		}
	}
	switch {
	case strings.Contains(low, "connection refused"):
		return "Nothing is listening at " + host + "."
	case strings.Contains(low, "no such host"):
		return "The name in " + host + " doesn't resolve."
	case strings.Contains(low, "deadline exceeded"), strings.Contains(low, "timeout"), strings.Contains(low, "timed out"):
		if host == "that address" {
			return "It didn't answer in time."
		}
		return host + " didn't answer in time."
	case strings.Contains(low, "x509"), strings.Contains(low, "certificate"), strings.Contains(low, "tls:"):
		return "The TLS certificate at " + host + " wasn't accepted."
	case strings.Contains(low, "executable file not found"):
		return "The command isn't on the server's PATH."
	case strings.Contains(low, "config saved yet"):
		return "Nothing is saved yet. Save the settings first."
	case strings.Contains(low, "credentials are incomplete"):
		return "It needs both keys."
	}
	if m := statusCode.FindStringSubmatch(raw); m != nil {
		code, _ := strconv.Atoi(m[1])
		h := " (HTTP " + m[1] + ")."
		switch {
		case code == 401 || code == 403:
			return service + " refused the credentials" + h
		case code == 404:
			return "Nothing at " + host + " answers this API" + h + " Check the URL."
		case code == 429:
			return service + " is limiting requests" + h + " Try again shortly."
		case code >= 500:
			return service + " had an error" + h
		case code >= 400:
			return service + " refused the request" + h
		}
	}
	if m := exitStatus.FindStringSubmatch(raw); m != nil {
		return "The command exited with status " + m[1] + "."
	}
	return ""
}
