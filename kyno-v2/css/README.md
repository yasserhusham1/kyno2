# css/

ملفات التنسيق — مقسّمة بوضوح.

---

## الهيكل

```
css/
├── app.css              ← CSS الرئيسي (imports الكل)
├── components/
│   ├── sidebar.css
│   ├── cards.css
│   ├── tables.css
│   ├── forms.css
│   ├── modals.css
│   └── buttons.css
└── themes/
    ├── dark.css
    └── light.css
```

---

## المبدأ

- `app.css` يستورد الملفات الأخرى بالترتيب
- كل component في ملفه المنفصل
- لا inline styles في HTML
- Variables CSS في `:root` لكل الألوان والمسافات
