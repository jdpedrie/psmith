package web

// Copy the profile templates compute from their view models.

func generalAction(vm profileGeneralVM) string {
	if vm.New {
		return "/settings/profiles"
	}
	return "/settings/profiles/" + vm.Head.ID
}

func defaultDetail(vm profileGeneralVM) string {
	if vm.DefaultName != "" && !vm.IsDefault {
		return "New conversations start here. " + vm.DefaultName + " is the default now."
	}
	return "New conversations start here."
}

func systemNote(vm profileGeneralVM) string {
	if vm.Head.ParentName != "" {
		return "Replaces " + vm.Head.ParentName + "'s prompt. Leave it empty to inherit that one."
	}
	return "Sent before every conversation on this profile."
}

func sbSelectedLabel(opts []sbOpt) string {
	for _, o := range opts {
		if o.Selected {
			return o.Label
		}
		for _, g := range o.Items {
			if g.Selected {
				return g.Label
			}
		}
	}
	return ""
}

func attachedNote(vm profilePluginsVM) string {
	if len(vm.Attached) == 0 {
		return "Attached plugins run in this order, after the inherited ones."
	}
	if vm.CredName != "" {
		return "Remove takes effect when you save. Credentials like the " + vm.CredName + " key are set once in Plugins, for every profile."
	}
	return "Remove takes effect when you save. Shared settings, like API keys, are set once in Plugins for every profile."
}

func chainLabel(vm profileShareVM) string {
	if vm.ChainLen <= 2 {
		return vm.Head.Name + " and " + vm.Head.ParentName + ", as two profiles"
	}
	return vm.Head.Name + " and the " + sbPlural(vm.ChainLen-1, "profile") + " above it, as " + sbPlural(vm.ChainLen, "profile")
}

func importHome(from string) string {
	if from == "" {
		return "/settings/profiles/import"
	}
	return "/settings/profiles/" + from + "/share"
}
