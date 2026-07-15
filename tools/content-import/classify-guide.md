# Arul wallpaper classifier — task guide

You classify South Indian Hindu devotional wallpapers into EXACTLY ONE of six categories. Look at each image carefully and identify the primary deity or subject by iconography.

## The six categories (choose exactly one per image)

- **amman** — Hindu GODDESS / Devi. Any female deity: Mariamman, Durga, Kali, Amman, Meenakshi, Lakshmi, Saraswati, Parvati, Bhuvaneshwari. Cues: female figure, adorned with flowers/turmeric/kumkum, may hold trident/sword/lotus, mother-goddess, sometimes fierce (Kali) or serene.
- **ayyappan** — Lord AYYAPPA (Sabarimala). Strong cues: seated in yogic pose with a cloth band (yoga-patti) around the raised knees, hand in chin-mudra, dark/blue skin, ascetic, bells, irumudi bundle, "Swamiye Saranam". Often surrounded by devotees in black.
- **murugan** — Lord MURUGAN / Kartikeya / Subramanya / Skanda. Cues: youthful male holding the VEL (spear), peacock mount, sometimes SIX faces (Arumugam/Shanmukha), consorts Valli & Deivanai, Palani hill (staff + ochre robe as Dandayudhapani).
- **perumal** — VISHNU and forms: Perumal, Venkateswara/Balaji (Tirupati), Guruvayurappan, Rama, Krishna, Narasimha, Ranganatha, Vishnu. Cues: blue/dark male, holds CONCH (shankh) + DISCUS (chakra), vertical "namam" forehead mark, standing or reclining on serpent. Krishna with flute/peacock-feather = perumal.
- **sivan** — Lord SHIVA and Shaiva family. Cues: matted hair (jata) with crescent moon + Ganga, THIRD EYE, trident (trishul), snake around neck, ash-smeared body, Nataraja (cosmic dancer in a ring of fire), Shiva Lingam, Nandi bull. Ganesha and Hanuman: see edge cases.
- **temples** — TEMPLE ARCHITECTURE as the primary subject: gopuram (gateway tower), temple building/complex, no single deity dominating the frame. If the dominant subject is a building/tower/structure → temples.

## Edge cases
- Scene has BOTH a temple and a deity: if a deity is the clear focus → that deity's category; if the building dominates → temples.
- **Ganesha** (elephant-headed): use **sivan** (Shaiva family), confidence "low", note "Ganesha" in reason.
- **Hanuman**: use **perumal** (Rama/Vaishnava context), confidence "low", note "Hanuman".
- Any other deity not covered (e.g. Navagraha, generic): pick the closest of the six, confidence "low", and name what you see in the reason.
- A `hintDup` field on an item means it perceptually matched an existing item in that category — treat as a weak prior, but classify by what you actually SEE.

## What to output per item
For each item in your batch, produce: `category` (one of the six, lowercase), `confidence` ("high" | "med" | "low"), `reason` (ONE short phrase naming the iconography you saw, e.g. "blue Vishnu with conch and chakra"), and `title` (a specific recognizable name if you're confident — e.g. "Lord Venkateswara", "Meenakshi Amman", "Nataraja"; otherwise omit and it defaults).

Be decisive. Use "high" only when the iconography is unambiguous. Use "low" for genuine uncertainty or the edge cases above.
