#!/usr/bin/env bash
# Slice 1 scaffolding stub for the "ntopng" step. Real check/apply
# logic ships with the slice that owns this component (tech.md 17).
# Every step is a (check, apply, plan) triple (tech.md section 5).

step_ntopng_check() {
	# Nothing to configure yet, so the step is always already satisfied.
	return 0
}

step_ntopng_apply() {
	log "INFO" "ntopng: stub apply, nothing to do yet"
	return 0
}

step_ntopng_plan() {
	echo "ntopng: без изменений"
}
