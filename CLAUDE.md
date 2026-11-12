> טיוטה שנוצרה אוטומטית מקריאת קבצי המאגר. יש לאמת פרטים לפני הסתמכות.

# עדכון אופליין - מאגר ספרים

תוכנת שולחן עבודה (Flutter/Dart, Windows ו-macOS) שמעדכנת את מאגר הספרים `YairDaniel11/Otzarya-Unofficial-Books` במחשבים שאינם מחוברים לרשת, ומעדכנת את מסד SQLite של אוצריא.

## מבנה
- `lib/main.dart` - כניסה.
- `lib/src/pak/` - פורמט PAK יחיד (`pak_file`, `crc32`, `zip_reader`): קבצים דחוסים פעם אחת (לפי גודל+CRC), אינדקס בסוף הקובץ, הכותרת נכתבת אחרונה (עמידות להפסקה), יש "דחיסה מחדש" (compact).
- `lib/src/db/` - עדכון המסד: `db_manifest`, `db_service`, `db_controller`, `zstd_stream` (קבצי `*.patch.zst` ו-`*.db.zst`, אימות SHA-256).
- `lib/src/services/` - `repo_service` (הורדה מ-GitHub), `otzaria_locator`, `app_paths`, `zip_extract`, `windows_parent`.
- `lib/src/update/` - בדיקת עדכון עצמי של התוכנה.
- `lib/src/screens/` - בית, מאגר, מסד, חילוץ, העתקה, TXT, הגדרות.
- `test/` - `pak_file`, `db`, `otzaria_locator`, `zip_extract`, `screens_smoke`, `live_repo_test` (שם מרמז על גישה לרשת - לא נבדק).

## בנייה והרצה
מה-workflow (לא הורצו): `flutter pub get`, `flutter analyze`, `flutter test`,
`flutter build <windows|macos> --release --build-name=<גרסה> --dart-define=APP_VERSION=<גרסה>`.
הרצה מקומית: לא מתועד, לא נבדק.

## שחרור / CI
`.github/workflows/build.yml`: push ל-`main` (בלי md/docs), תגי `v*`, והפעלה ידנית.
- `version`: תג `v*` או העלאת patch מהתג האחרון.
- `build`: analyze (לא חוסם), test, build, `BooksOfflineUpdate.exe` יחיד (7-Zip SFX + rcedit, מניפסט asInvoker כדי למנוע בקשת UAC בגלל השם "Update") ל-Windows; zip לא חתום ל-macOS.
- `release`: Release בכל ריצה מוצלחת.

## מוסכמות ומלכודות
- ה-exe היחיד מחלץ את עצמו לתיקייה זמנית; התוכנה מזהה את ה-exe המקורי ושומרת את `OtzariaBooks.pak` לידו (לפי ההערה ב-workflow).
- ה-README מתאר מסד מראה `OtzariaDbMirror` וגרסאות `db`/`db-v<N>` ב-Releases של מאגר הספרים - תלות במבנה המאגר החיצוני.
- `pubspec.yaml` מציג `1.0.0+1` וגם `description: "A new Flutter project."` (ברירת מחדל); הגרסה האמיתית מתגי git.
- כל push ל-`main` שנוגע בקוד יוצר Release.

## מצב נוכחי
- ענף: `main`, remote: `https://github.com/YairDaniel11/Books-Offline-Updater.git`.
- `git status -sb`: נקי, מסונכרן עם `origin/main`.
- קומיטים אחרונים: הכנת קבצים למחשב ללא רשת עם בחירת גרסת מקור ידנית, בחירת תיקייה למסד חדש, צירוף אוטומטי של המסד לאוצריא, לשונית "העתקת הספרים".
