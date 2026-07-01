package main

import "testing"

func TestLocaleFallbackLanguage(t *testing.T) {
	cases := map[string]string{
		"zh_CN":      "Simplified Chinese",
		"zh-Hans":    "Simplified Chinese",
		"zh_TW":      "Traditional Chinese",
		"zh-Hant-HK": "Traditional Chinese",
		"ja_JP":      "Japanese",
		"ko_KR":      "Korean",
		"en_US":      "English",
		"es_MX":      "Spanish",
		"fr_FR":      "French",
		"de_DE":      "German",
		"pt_BR":      "Portuguese",
		"ru_RU":      "Russian",
		"ar_SA":      "Arabic",
		"hi_IN":      "Hindi",
		"th_TH":      "Thai",
		"vi_VN":      "Vietnamese",
		"id_ID":      "Indonesian",
		"tr_TR":      "Turkish",
		"pl_PL":      "Polish",
		"nl_NL":      "Dutch",
		"ms_MY":      "Malay",
	}
	for locale, want := range cases {
		if got := localeFallbackLanguage(locale); got != want {
			t.Errorf("localeFallbackLanguage(%q) = %q, want %q", locale, got, want)
		}
	}
}
