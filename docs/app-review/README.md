# App Review information response

Prepared on 7 November 2026 for Apple's Guideline 2.1 information request.
The six numbered sections in [notes.txt](notes.txt) are a draft for the
App Review Information **Notes** field. Replace every bracketed placeholder
before submission.

The developer confirmed that physical-device testing and recording are complete,
that the United Kingdom is currently included in App Store availability, and
that there is no separate UK KJV permission. Recording details are intentionally
left blank at the developer's request.

The feature descriptions were checked against the current source and
[user guide](../user-guide.md). The recording, physical-device test results,
uploaded binary and live App Store Connect configuration were not independently
inspected during this preparation.

## Complete the recording details

Add the recording URL, physical device model, OS version and submitted app
version/build. Check that the recording uses the submitted build, begins with
launching the app, and shows the main features. Apple specifically requested a
physical device running the latest operating system.

Make the recording accessible to the reviewer without an access-request flow,
and check its link in a signed-out browser. Keep it available throughout review.
If the recording covers one device, list any additional supported device
platforms tested separately without suggesting they appear in that recording.

Use this checklist to assess the existing recording:

1. Begin on the Home Screen and launch SimpleScripture.
2. Open a passage through the reference picker and navigate a chapter.
3. Switch between Bible and Commentary.
4. Enable Strong's Numbers and open a definition; optionally show Greek
   morphology.
5. Search the Bible and open a result. On a fresh installation, demonstrate
   Build Index if it is offered.
6. Save a bookmark and find it again in Library; show history and a dictionary.
7. Adjust font size and open About > Credits & licenses.
8. If useful, briefly demonstrate that reading and search work offline.

Registration, account deletion, public-content moderation and purchases are
not applicable to the current app. Personal bookmark descriptions do not
constitute an in-app public posting service. The optional GitHub feedback
destination is an external service.

## Resolve the UK KJV documentation

Cambridge's [current rights and permissions page](https://www.cambridge.org/au/universitypress/bibles/about/rights-and-permissions),
checked on 7 November 2026, states that UK rights in the Authorized Version
are vested in the Crown. Its limited permission covers up to 500 verses
for liturgical and non-commercial educational use, subject to further
conditions; requests exceeding those guidelines require written approval.
That quotation allowance does not cover bundling the complete Bible.

The app's [KJV notice](../../Resources/Notices/KJV.txt) preserves CrossWire's
grant for its electronic work and separately acknowledges the Crown rights.
Do not describe the entire KJV as public domain worldwide or claim that this
notice establishes separate UK authorization.

Choose the appropriate route before finalizing sections 5 and 6:

- **Retain UK availability:** obtain documentation covering the intended
  full-text app distribution and identify/attach it for review. Cambridge's
  page provides the permission-request route. Do not use permission wording
  before approval exists.
- **Exclude the UK storefront:** change and verify the availability setting in
  App Store Connect, then replace the section 5 placeholder with
  “The app is not offered in the United Kingdom storefront.” Replace the
  section 6 placeholder with “The United Kingdom storefront is excluded.”
  These statements become accurate only after the setting has changed.

Storefront exclusion limits that distribution channel. It does not establish
UK permission for other distribution, including the public source/data
repository, or prove that no user physically in the UK can access the app.

## Supporting documentation and submission

The public repository and its notice directory were verified during preparation:

- [Bundled content and font notices](https://github.com/timTam97/simplescripture/tree/main/Resources/Notices)
- [Application GPLv2 licence](https://github.com/timTam97/simplescripture/blob/main/Resources/doc/LICENSE.txt)
- [Local notice provenance](../licensing/about-notices.md)

Confirm that these documents describe the submitted build. If Apple requests
attachments, provide the relevant original notices and any actual permission
documents. A developer-written summary is an index to the evidence, not a new
permission grant. Keep corresponding application source matched to the
distributed binary.

After filling in the details and resolving the regional/content statement,
paste notes.txt into App Review Information > Notes, add the relevant
attachments, and resubmit as Apple requested. Check the Notes field's character
limit after substituting URLs and details. The quoted message asks for
information and does not identify a specific crash or mandate a new binary.
