package testkit

import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import json "../json"
import model "../core/model"

@(private = "file")
json_checks :: proc() -> typed.Format_Checks {
	return json.checks(.Json)
}

// The plan of `T`'s model with no registered rules, in the temp allocator, checked as `checks` names, JSON's for nil.
ruled_plan :: proc($T: typeid, enums := typed.Enum_Spelling.Name, checks: Maybe(typed.Format_Checks) = nil) -> typed.Plan {
	reg := model.Registry{naming = {enums = enums}}
	m, _ := model.compile(&reg, T, checks.? or_else json_checks(), context.temp_allocator)
	// The model's plan refuses reads, and these tests read by it to compare the read with the schema.
	plan := m.plan
	plan.model_plan = .None
	return plan
}

// The load description of a plan under test, through a model that holds it.
description_of :: proc(plan: ^typed.Plan, allocator := context.allocator) -> (rules.Description, core.Error) {
	m := model.Model(struct{}){plan = plan^}
	return model.schema(&m, .Load, allocator)
}
