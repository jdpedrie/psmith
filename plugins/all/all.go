// Package all links every built-in plugin into the binary.
//
// Each plugin registers itself from init(), so a plugin that nobody imports
// is a plugin that does not exist. When they all shared one package a single
// import got all of them; now that each has its own, something has to name
// them. This is the standard database/sql driver pattern.
//
// A placeholder, not a design. Registration is about to move to
// activate-by-config with hot-swap into a running server, and a core-versus-
// optional split. This file preserves today's behaviour until then.
package all

import (
	_ "github.com/jdpedrie/psmith/plugins/app_tools"
	_ "github.com/jdpedrie/psmith/plugins/basic_grounding"
	_ "github.com/jdpedrie/psmith/plugins/brave_search"
	_ "github.com/jdpedrie/psmith/plugins/component_builder"
	_ "github.com/jdpedrie/psmith/plugins/context_packs"
	_ "github.com/jdpedrie/psmith/plugins/files"
	_ "github.com/jdpedrie/psmith/plugins/game_master"
	_ "github.com/jdpedrie/psmith/plugins/imagegen"
	_ "github.com/jdpedrie/psmith/plugins/lettered_choices"
	_ "github.com/jdpedrie/psmith/plugins/mcp"
	_ "github.com/jdpedrie/psmith/plugins/memory"
	_ "github.com/jdpedrie/psmith/plugins/text_injector"
)
