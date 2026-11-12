/// מזהי המסכים: דף הבית, ומסכי המשנה שנפתחים מכרטיסי הבית.
abstract final class Tabs {
  static const home = 0, db = 1, txt = 2, copy = 3, settings = 4, prepare = 5;

  /// כותרת המסך (בסרגל העליון של מסכי המשנה).
  static String title(int i) => switch (i) {
        db => 'אפשרויות מסד הספרים',
        txt => 'ספרים בודדים',
        copy => 'העתקה מהכונן',
        settings => 'הגדרות',
        prepare => 'הכנה למחשב בלי אינטרנט',
        _ => 'עדכון מסד הספרים',
      };
}
