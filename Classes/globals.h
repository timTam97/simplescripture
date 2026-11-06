/*
 *  globals.h
 *  MacSword2
 *
 *  Created by Manfred Bergmann on 03.06.05.
 *  Copyright 2007 mabe. All rights reserved.
 *
 */

// $Author: $
// $HeadURL: $
// $LastChangedBy: $
// $LastChangedDate: $
// $Rev: $

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// we can add more to this enum as we're required to dynamically show those tabs
typedef NS_ENUM(NSInteger, ShownTab) {
    BibleTab = 1,
    CommentaryTab,
	DictionaryTab,
	// DevotionalTab and DownloadsTab are dead placeholders kept so that the
	// enum ordinals do not shift (they may be persisted in NSUserDefaults).
	// The devotional and in-app download features have both been removed.
	DevotionalTab,
	DownloadsTab,
	PreferencesTab
};

typedef NS_ENUM(NSInteger, ShownMultiListTab) {
	HistoryTab = 0,
	SearchTab
};

typedef NS_ENUM(NSInteger, PSSearchType) {
	AndSearch = 0,
	OrSearch,
	ExactSearch
};

typedef NS_ENUM(NSInteger, PSSearchRange) {
	AllRange = 0,
	OTRange,
	NTRange,
	BookRange
};

#pragma mark - Constants migrated out of the SWORD headers (Phase 5 step 2)

// Values formerly declared by the SWORD bridge headers, still used by Swift.
// The `#ifndef` guards are harmless leftovers; the values are wire strings and
// must not change.

// Keys for passagestudy link data and reference-list output.
#ifndef SW_OUTPUT_TEXT_KEY
#define SW_OUTPUT_TEXT_KEY  @"OutputTextKey"
#endif
#ifndef SW_OUTPUT_REF_KEY
#define SW_OUTPUT_REF_KEY   @"OutputRefKey"
#endif

#ifndef ATTRTYPE_TYPE
#define ATTRTYPE_TYPE       @"type"
#endif
#ifndef ATTRTYPE_PASSAGE
#define ATTRTYPE_PASSAGE    @"passage"
#endif
#ifndef ATTRTYPE_MODULE
#define ATTRTYPE_MODULE     @"modulename"
#endif
#ifndef ATTRTYPE_ACTION
#define ATTRTYPE_ACTION     @"action"
#endif
#ifndef ATTRTYPE_VALUE
#define ATTRTYPE_VALUE      @"value"
#endif

// Module feature strings: the keys the baked feature set in content_meta is
// queried with.
#ifndef SWMOD_CONF_FEATURE_STRONGS
#define SWMOD_CONF_FEATURE_STRONGS       @"StrongsNumbers"
#endif
#ifndef SWMOD_CONF_FEATURE_GREEKDEF
#define SWMOD_CONF_FEATURE_GREEKDEF      @"GreekDef"
#endif
#ifndef SWMOD_CONF_FEATURE_HEBREWDEF
#define SWMOD_CONF_FEATURE_HEBREWDEF     @"HebrewDef"
#endif
#ifndef SWMOD_CONF_FEATURE_GREEKPARSE
#define SWMOD_CONF_FEATURE_GREEKPARSE    @"GreekParse"
#endif
#ifndef SWMOD_CONF_FEATURE_IMAGES
#define SWMOD_CONF_FEATURE_IMAGES        @"Images"
#endif

// `ModuleType`, used by its bare cases from Swift. Case names and values are
// fixed.
#ifndef PS_MODULETYPE_DEFINED
#define PS_MODULETYPE_DEFINED
typedef enum {
	unknown_type = -1,
	bible       = 0x0001,
	commentary  = 0x0002,
	dictionary  = 0x0004,
	genbook     = 0x0008
}ModuleType;
#endif

#define DefaultsModuleCipherKeysKey					@"DefaultsModuleCipherKeysKey"
#define DefaultsLastRef								@"lastRef"
#define DefaultsLastBible							@"lastBible"
#define DefaultsLastCommentary						@"lastCommentary"
#define DefaultsLastDictionary						@"lastDictionary"

#define DefaultsLastMultiListTab					@"DefaultsLastMultiListTab"
#define DefaultsLastSearchFuzzy						@"DefaultsLastSearchFuzzy"
#define DefaultsLastSearchType						@"DefaultsLastSearchType"
#define DefaultsLastSearchRange						@"DefaultsLastSearchRange"
#define DefaultsLuceneSwept							@"DefaultsLuceneSwept"
#define DefaultsSimplifiedCleanupDone				@"DefaultsSimplifiedCleanupDone"
#define DefaultsModuleChoiceRetired					@"DefaultsModuleChoiceRetired"
#define DefaultsGlobalFontOnly						@"DefaultsGlobalFontOnly"
#define DefaultsLastRefValidated					@"DefaultsLastRefValidated"
#define DefaultsDictKeyCaseFixed					@"DefaultsDictKeyCaseFixed"

#define DefaultsBibleVersePosition					@"bibleVersePosition"
#define DefaultsCommentaryVersePosition				@"commentaryVersePosition"

#define DEFAULT_MODULE_PATH_OLD     [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex: 0] stringByAppendingString: @"/"]
#define DEFAULT_MODULE_PATH         [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex: 0] stringByAppendingString: @"/"]
#define DEFAULT_BUILTIN_MODULE_PATH	[[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex: 0] stringByAppendingString: @"/Built-in/"]
#define DEFAULT_APPSUPPORT_PATH     [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex: 0] stringByAppendingString: @"/"]
#define DEFAULT_BOOKMARKS_PATH		[[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex: 0] stringByAppendingString: @"/"]

#define DEFAULT_INSTALLER_PATH		[[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex: 0] stringByAppendingString: @"/InstallMgr/"]
#define DEFAULT_MMM_PATH			[NSTemporaryDirectory() stringByAppendingPathComponent:@"MMM"]


// define for userdefaults
#define userDefaults [NSUserDefaults standardUserDefaults]

// Default Modules
// RETIRED: never written or read. A set flag would suppress a bundled module
// forever, so the DefaultsModuleChoiceRetired migration clears any that are set.
// Kept declared so the names are not reused.
#define DefaultsKJVRemoved							@"DefaultsKJVRemoved"
#define DefaultsMHCCRemoved							@"DefaultsMHCCRemoved"
#define DefaultsStrongsRealHebrewRemoved			@"DefaultsStrongsRealHebrewRemoved"
#define DefaultsRobinsonRemoved						@"DefaultsRobinsonRemoved"
#define DefaultsStrongsRealGreekRemoved				@"DefaultsStrongsRealGreekRemoved"

// Preferences - general
// RETIRED, NOT REUSABLE: the lexicon-role keys are never read or written — the
// roles are hardcoded (BundledModules in AppConstants.swift). A stale value can be
// the localized string "None", so honouring one would break Strong's / morph lookups.
#define DefaultsStrongsHebrewModule                 @"DefaultsStrongsHebrewModule"
#define DefaultsStrongsGreekModule                  @"DefaultsStrongsGreekModule"
#define DefaultsMorphHebrewModule                   @"DefaultsMorphHebrewModule"
#define DefaultsMorphGreekModule                    @"DefaultsMorphGreekModule"
#define DefaultsInsomniaPreference					@"insomniaPreference"

// Preferences - per module
#define GetBoolPrefForMod(Pref,Mod)			[[NSUserDefaults standardUserDefaults] boolForKey:[NSString stringWithFormat:@"%@_%@", Pref, Mod]]
#define GetStringPrefForMod(Pref,Mod)		[[NSUserDefaults standardUserDefaults] stringForKey:[NSString stringWithFormat:@"%@_%@", Pref, Mod]]
#define GetIntegerPrefForMod(Pref,Mod)		[[NSUserDefaults standardUserDefaults] integerForKey:[NSString stringWithFormat:@"%@_%@", Pref, Mod]]
#define SetBoolPrefForMod(b,Pref,Mod)		[[NSUserDefaults standardUserDefaults] setBool:b forKey:[NSString stringWithFormat:@"%@_%@", Pref, Mod]]
#define SetObjectPrefForMod(o,Pref,Mod)		[[NSUserDefaults standardUserDefaults] setObject:o forKey:[NSString stringWithFormat:@"%@_%@", Pref, Mod]]
#define SetIntegerPrefForMod(i,Pref,Mod)	[[NSUserDefaults standardUserDefaults] setInteger:i forKey:[NSString stringWithFormat:@"%@_%@", Pref, Mod]]
#define RemovePrefForMod(Pref,Mod)			[[NSUserDefaults standardUserDefaults] removeObjectForKey:[NSString stringWithFormat:@"%@_%@", Pref, Mod]]

		// from createHTMLString:
#define DefaultsFontNamePreference					@"fontNamePreference"
#define DefaultsFontSizePreference					@"fontSizePreference"
#define DefaultsFontDefaultsPreference				@"fontDefaultsPreference"

		// from attributeValueForEntryData: && getChapter:
#define DefaultsStrongsPreference					@"strongsPreference"
#define DefaultsMorphPreference						@"morphPreference"
#define DefaultsScriptRefsPreference				@"scriptRefsPreference"
#define DefaultsFootnotesPreference					@"footnotesPreference"
#define DefaultsHeadingsPreference					@"headingsPreference"
#define DefaultsRedLetterPreference					@"redLetterPreference"
#define DefaultsVPLPreference						@"vplPreference"
#define DefaultsGreekAccentsPreference				@"greekAccentsPreference"
#define DefaultsHVPPreference						@"hvpPreference"
#define DefaultsHebrewCantillationPreference		@"hebrewCantillationPreference"
#define DefaultsGlossesPreference					@"glossesPreference"

#define StrongsFontName								@"Times New Roman"
#define PSGreekStrongsFontName						@"Gentium Plus"
#define PSHebrewStrongsFontName						@"Ezra SIL"
#define PSDefaultFontName							@"Georgia"
#define PSFolderSeparatorString						@":::"
#define PSHistoryMaxEntries							100
#define PSHistoryName								@"bibleHistory"

#define BookNameString								@"BookNameString"
#define ChapterString								@"ChapterString"
#define VerseString									@"VerseString"

#define BibleTabTitleString							@"BibleTabTitleString"
#define CommentaryTabTitleString					@"CommentaryTabTitleString"

// Notification identifiers
#define NotificationBibleSwipeRight				@"NotificationBibleSwipeRight"
#define NotificationBibleSwipeLeft				@"NotificationBibleSwipeLeft"
#define NotificationCommentarySwipeRight		@"NotificationCommentarySwipeRight"
#define NotificationCommentarySwipeLeft			@"NotificationCommentarySwipeLeft"

#define NotificationRefSelectorResetBooks		@"NotificationRefSelectorResetBooks"
#define NotificationNewPrimaryBible				@"NotificationNewPrimaryBible"
#define NotificationNewPrimaryCommentary		@"NotificationNewPrimaryCommentary"
#define NotificationNewPrimaryDictionary		@"NotificationNewPrimaryDictionary"
#define NotificationReloadDictionaryData		@"NotificationReloadDictionaryData"
#define NotificationResetBibleAndCommentaryView @"NotificationResetBibleAndCommentaryView"

#define NotificationRedisplayPrimaryBible		@"NotificationRedisplayPrimaryBible"
#define NotificationRedisplayPrimaryCommentary	@"NotificationRedisplayPrimaryCommentary"
#define NotificationBookmarksChanged			@"NotificationBookmarksChanged"
#define NotificationHistoryChanged				@"NotificationHistoryChanged"

#define NotificationToggleMultiList				@"NotificationToggleMultiList"
#define NotificationToggleNavigation            @"NotificationToggleNavigation"

#define NotificationHideInfoPane				@"NotificationHideInfoPane"
#define NotificationShowInfoPane				@"NotificationShowInfoPane"
#define NotificationRotateInfoPane				@"NotificationRotateInfoPane"

#define NotificationShowCommentaryTab			@"NotificationShowCommentaryTab"
#define NotificationShowBibleTab				@"NotificationShowBibleTab"

#define NotificationAddBookmarkInFolder			@"NotificationAddBookmarkInFolder"

#define NotificationUpdateSelectedReference		@"NotificationUpdateSelectedReference"

#define ROTATION_LOCK_POSITION					@"rotationLockedPosition"

typedef NS_ENUM(NSInteger, RotationPosition) {
	RotationEnabled,
	RotationLockedInPortrait,
	RotationLockedInLandscape
};

