//
//  SimpleScripture-Bridging-Header.h
//  SimpleScripture
//
//  The app target contains no Objective-C implementation; the only thing Swift
//  imports through here is globals.h. Keep it that way.
//

// globals.h: the Defaults* / notification-name / ShownTab / PSSearch* constants
// and enums (PSSearchType / PSSearchRange / ShownTab / ModuleType), plus the
// ATTRTYPE_* / SW_OUTPUT_*_KEY / SWMOD_* literals. Classes/AppConstants.swift
// mirrors every wire string BYTE-FOR-BYTE — change a literal in one, change it in
// the other, or persisted data breaks.
#import "globals.h"
