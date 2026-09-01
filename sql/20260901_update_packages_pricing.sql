-- Update diamond packages to 5 tiers with new pricing
-- GHC 350 = 2💎, GHC 500 = 3💎, GHC 850 = 5💎, GHC 1000 = 7💎, GHC 1500 = 10💎

UPDATE public.settings SET
  diamond_packages = '[
    {"id":"starter","name":"Starter","diamonds":2,"ghs":350,"ngn":35000,
     "features":["3 match predictions","Standard accuracy","Email support"],
     "example":"Man City vs Liverpool → Home Win 2-1 (82%)",
     "popular":false,"tone":"emerald"},
    {"id":"pro","name":"Pro","diamonds":3,"ghs":500,"ngn":50000,
     "features":["10 match predictions","Gemini AI analysis","Priority processing","Score + goals tips"],
     "example":"Arsenal vs Chelsea → Home Win 3-1 (89%) + Over 2.5 goals",
     "popular":true,"tone":"gold"},
    {"id":"standard","name":"Standard","diamonds":5,"ghs":850,"ngn":85000,
     "features":["20 match predictions","Gemini AI analysis","Priority processing","Score + goals tips","Detailed stats"],
     "example":"Barcelona vs PSG → Home Win 2-1 (91%) + BTTS Yes",
     "popular":false,"tone":"emerald"},
    {"id":"premium","name":"Premium","diamonds":7,"ghs":1000,"ngn":100000,
     "features":["Unlimited predictions","Gemini AI + screenshot OCR","Instant processing","Full analysis + notes","VIP support"],
     "example":"Real Madrid vs Barcelona → Draw 2-2 (94%) + BTTS Yes",
     "popular":false,"tone":"ice"},
    {"id":"elite","name":"Elite","diamonds":10,"ghs":1500,"ngn":150000,
     "features":["Unlimited predictions","Gemini AI + screenshot OCR","Instant processing","Full analysis + notes","VIP support","Priority support"],
     "example":"Man City vs Liverpool → Home Win 3-1 (96%) + Over 2.5 goals",
     "popular":false,"tone":"gold"}
  ]'::jsonb,
  gold_packages = '[
    {"id":"gold-basic","name":"Basic","coins":2,"ghs":350,"ngn":35000,
     "features":["3 spin reveals","Standard signals","Email support"],
     "example":"Tomorrow 14:00 → Man City Win (78%)",
     "popular":false,"tone":"emerald"},
    {"id":"gold-pro","name":"Pro","coins":3,"ghs":500,"ngn":50000,
     "features":["10 spin reveals","AI-powered signals","Priority processing","Score predictions"],
     "example":"Tomorrow 16:30 → Arsenal Win 2-1 (85%) + BTTS",
     "popular":true,"tone":"gold"},
    {"id":"gold-standard","name":"Standard","coins":5,"ghs":850,"ngn":85000,
     "features":["20 spin reveals","AI-powered signals","Priority processing","Score predictions","Detailed stats"],
     "example":"Liverpool vs Arsenal → Draw 1-1 (88%) + Under 2.5",
     "popular":false,"tone":"emerald"},
    {"id":"gold-premium","name":"Premium","coins":7,"ghs":1000,"ngn":100000,
     "features":["Unlimited reveals","Full AI analysis","Instant processing","Detailed match notes","VIP support"],
     "example":"Liverpool vs Chelsea → Draw 2-2 (91%) + Over 2.5",
     "popular":false,"tone":"ice"},
    {"id":"gold-elite","name":"Elite","coins":10,"ghs":1500,"ngn":150000,
     "features":["Unlimited reveals","Full AI analysis","Instant processing","Detailed match notes","VIP support","Priority support"],
     "example":"Man City vs Arsenal → Home Win 2-1 (93%) + BTTS Yes",
     "popular":false,"tone":"gold"}
  ]'::jsonb
WHERE id = 'global_config';

SELECT '✅ Packages updated — 5 tiers each with new pricing' AS result;
