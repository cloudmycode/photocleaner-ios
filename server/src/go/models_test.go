package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestMustMatchMarshalJSONNoNull(t *testing.T) {
	cases := []MustMatch{
		{},
		{SensitiveTypes: []string{"id_card"}},
		{VisualTagsAll: []string{"cat"}},
		{VisualTagsAll: []string{"beach", "person"}}, // sensitiveTypes/ocr nil
	}
	for i, m := range cases {
		data, err := json.Marshal(m)
		if err != nil {
			t.Fatalf("case %d: %v", i, err)
		}
		if strings.Contains(string(data), "null") {
			t.Fatalf("case %d: must not contain null: %s", i, data)
		}
	}
}

func TestSearchPlanMarshalJSONNoNullInMust(t *testing.T) {
	plan := SearchPlan{
		Summary: "身份证",
		Must:    MustMatch{SensitiveTypes: []string{"id_card"}},
		Count:   1000,
	}
	data, err := json.Marshal(plan)
	if err != nil {
		t.Fatal(err)
	}
	body := string(data)
	if strings.Contains(body, "null") {
		t.Fatalf("unexpected null: %s", body)
	}
}
