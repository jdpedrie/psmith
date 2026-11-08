package web

import (
	"testing"

	"github.com/a-h/templ"
)

func TestProbeList(t *testing.T) {
	conv := boardConv()
	tpl := boardTemplates()
	anthropic := tpl[0]
	probeAll(t, []probeCase{
		{"SignIn", func() templ.Component {
			return signInScreen(signInVM{Server: "psmith.home", Username: "john", Password: "correcthorse", ShowFocus: true})
		}},
		{"SignInError", func() templ.Component {
			return signInScreen(signInVM{Server: "psmith.home", Username: "john", Error: "Invalid username or password."})
		}},
		{"OnboardProvider", func() templ.Component {
			return setupProviderScreen(setupVM{Templates: tpl, Template: anthropic})
		}},
		{"OnboardKey", func() templ.Component {
			return setupKeyScreen(setupVM{Template: anthropic, Label: "Anthropic", Key: "sk-ant-api03-7Qm2x9vLr4f2a", ShowFocus: true,
				Test: &testVM{OK: true, Message: "Connected in 312 ms. Found 6 models."}})
		}},
		{"OnboardModels", func() templ.Component {
			return setupModelsScreen(setupVM{Template: anthropic, ProviderID: "p1", Label: "Anthropic", Models: boardSetupModels()})
		}},
		{"Welcome", func() templ.Component { return welcomeScreen(boardListIdle(), boardWelcome(false)) }},
		{"ListPinned", func() templ.Component {
			return conversationScreen(boardListWith(func(l *listVM) {
				l.Rows[0].Group = "Today"
				l.Rows = append(boardPinnedRows(), l.Rows...)
			}), conv)
		}},
		{"ListSearch", func() templ.Component { return conversationScreen(boardSearchList(), conv) }},
		{"ListRowMenu", func() templ.Component {
			return conversationScreen(boardListWith(func(l *listVM) { l.MenuID = "c-council" }), conv)
		}},
		{"ListRowConfirm", func() templ.Component {
			return conversationScreen(boardListWith(func(l *listVM) { l.ConfirmID = "c-council" }), conv)
		}},
		{"ListRename", func() templ.Component {
			return conversationScreen(boardListWith(func(l *listVM) {
				l.RenameID = "c-council"
				l.Rows[2].Title = "Council: pricing for the 2027 plan"
			}), conv)
		}},
		{"ListSelect", func() templ.Component {
			return conversationScreen(boardListWith(func(l *listVM) {
				l.Select = true
				l.Selected = map[string]bool{"c-tax": true, "c-md": true, "c-tour": true}
			}), conv)
		}},
		{"ListEmpty", func() templ.Component {
			return welcomeScreen(listVM{Filter: "all", Sort: "used", Empty: true, Chips: boardChips("all"), UserName: "John", Initial: "J", Server: "psmith.home", IsAdmin: true}, boardWelcome(true))
		}},
		{"ListArchived", func() templ.Component { return conversationScreen(boardArchivedList(), conv) }},
		{"Offline", func() templ.Component {
			return conversationScreen(boardListWith(func(l *listVM) { l.Offline, l.RetryIn = true, "4s" }), boardOfflineConv())
		}},
		{"AccountMenu", func() templ.Component {
			return conversationScreen(boardListWith(func(l *listVM) { l.AccountOpen = true }), conv)
		}},
		{"Shortcuts", func() templ.Component { return shortcutsScreen(boardList(), &conv, welcomeVM{}) }},
		{"DraftStart", func() templ.Component { return draftScreen(boardListIdle(), boardDraft(true)) }},
		{"DraftNoProfile", func() templ.Component { return draftScreen(boardListIdle(), boardDraft(false)) }},
		{"Command", func() templ.Component {
			return conversationScreen(boardListWith(func(l *listVM) { c := boardCommand(); l.Command = &c }), conv)
		}},
		{"PhoneList", func() templ.Component {
			return welcomeScreen(boardListWith(func(l *listVM) {
				l.ActiveID = ""
				rows := boardListIdle().Rows[:6]
				l.Rows = append(boardPinnedRows()[:1], rows...)
			}), boardWelcome(false))
		}},
		{"PhoneDraft", func() templ.Component { return draftScreen(boardListIdle(), boardDraft(true)) }},
	}, nil)
}
