package strategygame

import "fmt"

// ImprovisedChoiceID is the reserved id an off-menu action is spliced in
// under. Reserved rather than model-chosen so it cannot collide with a
// listed option's id.
const ImprovisedChoiceID = "_improvised"

// PriceImprovised quotes a free-text action against the current state
// without changing anything.
//
// It goes through the same pricing path as an authored choice on
// purpose. The alternative — a separate, more forgiving path for
// improvised play — makes off-menu actions strictly better than the
// buttons, and once players notice that the listed options stop being
// decisions.
func PriceImprovised(st State, d ChoiceDraft) (Choice, error) {
	if st.Public.Situation == nil {
		return Choice{}, fmt.Errorf("no active situation to act on")
	}
	d.ID = ImprovisedChoiceID
	stats := map[string]bool{}
	ratings := map[string]bool{}
	for k := range st.Public.Resources {
		stats[k] = true
	}
	for k := range st.Public.Ratings {
		stats[k] = true
		ratings[k] = true
	}
	// Reuse the full draft validation by pricing a one-choice situation.
	// Situations require two choices to be a decision, but an improvised
	// action is the second option by construction — the player already
	// had the listed ones in front of them.
	if err := validateChoice(d, stats, ratings); err != nil {
		return Choice{}, err
	}
	target, err := TargetFor(d.Difficulty)
	if err != nil {
		return Choice{}, err
	}
	mod := st.Public.Ratings[d.Rating]
	return Choice{
		ID:         d.ID,
		Label:      d.Label,
		Rating:     d.Rating,
		Difficulty: d.Difficulty,
		Target:     target,
		Modifier:   mod,
		Odds:       OddsFor(mod, target),
		Stakes:     d.Stakes,
		Advances:   d.Advances,
		Costs:      d.Costs,
	}, nil
}

// AttachImprovised splices a priced off-menu action onto the current
// situation so Resolve can treat it as an ordinary choice. Returns a copy;
// the caller's state is untouched.
func AttachImprovised(st State, d ChoiceDraft) (State, error) {
	priced, err := PriceImprovised(st, d)
	if err != nil {
		return State{}, err
	}
	out := st.clone()
	sit := *out.Public.Situation
	sit.Choices = append(append([]Choice(nil), sit.Choices...), priced)
	out.Public.Situation = &sit
	out.Protocol.LegalChoiceIDs = append(append([]string(nil), out.Protocol.LegalChoiceIDs...), priced.ID)
	return out, nil
}
