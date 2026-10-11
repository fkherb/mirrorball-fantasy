Official authentication artwork, retrieved October 11, 2026.

Google:
- google-g.png is the current gradient G, unchanged, from
  https://developers.google.com/static/identity/images/g-logo.png
- google-sans-medium.ttf is the Google Fonts 500-weight subset for
  "Continue with Google"; its redistribution license is Google-Sans-OFL.txt.
- Brand specifications:
  https://developers.google.com/identity/branding-guidelines

Apple:
- apple-logo-black.svg and apple-logo-white.svg are the unmodified,
  medium, left-aligned SVGs from Apple's Sign in with Apple artwork pack:
  https://devimages-cdn.apple.com/design/resources/download/Logo-Sign-in-with-Apple.dmg
- Keep the entire 31x44 artwork at the button's height. Its background and
  padding are intentional. Black artwork goes on white buttons, and white
  artwork goes on black buttons.
- Use only for Sign in with Apple, subject to Apple's Developer Artwork
  License Agreement for Sign in with Apple (EA1677, January 30, 2020),
  included in the source pack.
- Brand specifications:
  https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple

Layout:
- Both providers use equal 44px touch targets and 14px medium labels with a
  20px line height. Google retains its prescribed Google Sans typography.
- Apple uses custom title typography to coordinate with the adjacent Google
  button, retaining the supplied logo, its full-height clear space, approved
  title and black/white treatment.

These buttons keep the existing Supabase OAuth and identity-linking actions.
No provider SDK is added and no additional provider requests run on page load.
