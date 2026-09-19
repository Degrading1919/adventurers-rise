---
name: tripo-3d-prompting
description: Explicitly invoked workflow for repository-grounded Tripo 3D prompting and reference preparation for Adventurer's Rise. Use when preparing or revising Tripo text-to-3D, image-to-3D, multiview, character/rig-preparation, or reusable asset-family inputs. Do not use to accept final production assets, invent missing art budgets, guarantee topology/polycount/rig quality, perform Blender cleanup, or replace owner visual approval and Roblox Studio validation.
---

# Adventurer's Rise Tripo 3D Prompting

Produce one ready-to-paste Tripo prompt package for one asset or one tightly related reusable asset family at a time.

The goal is not to make a Tripo result look impressive in isolation. The goal is to produce useful source geometry for the approved pipeline:

> **Tripo → Blender cleanup/optimization → Roblox Studio → in-game validation**

The final authority is how the cleaned asset performs and reads in Adventurer's Rise at normal gameplay distance on the target Roblox experience, including mobile.

## Operating boundary

- Require explicit invocation as `$tripo-3d-prompting`.
- Treat the Adventurer's Rise repository as the source of truth for game design, visual direction, asset reuse, progression role, and technical boundaries.
- Follow repository precedence: `docs/DESIGN_SOURCE_OF_TRUTH.md` first, then the most recent explicit owner decision, then dedicated agreed specifications. `docs/PLATFORM_REQUIREMENTS.md` applies where newer documents are silent.
- Treat raw Tripo output as source material, not an accepted production asset.
- Distinguish every important instruction as one of:
  - **official Tripo fact** — currently documented by Tripo;
  - **official Roblox fact** — currently documented by Roblox;
  - **approved Adventurer's Rise constraint** — recorded in the repository or explicitly approved by the project owner;
  - **working heuristic** — practical production advice that is not guaranteed by Tripo or Roblox.
- Never claim that prompt wording guarantees topology, exact polygon count, symmetry, segmentation, successful rigging, animation quality, UV quality, texture quality, mobile performance, or production readiness.
- Never invent a polygon, texture, material, collider, LOD, rig, or draw-call budget that the repository has not approved.
- Do not copy identifiable characters, brands, or protected designs. Use references to communicate broad shape, construction, material, and presentation ideas rather than requesting exact imitation.

## 1. Run repository preflight

Before writing a prompt, inspect the current relevant repository files.

Always begin with:

- `README.md`
- `docs/DESIGN_SOURCE_OF_TRUTH.md`
- `docs/PLATFORM_REQUIREMENTS.md`
- `docs/VERTICAL_SLICE.md` when the asset participates in the current slice

Then inspect the dedicated files and definitions that govern the requested asset.

Examples:

### Equipment and tools
- `docs/EQUIPMENT.md`
- `docs/ITEM_INVENTORY.md`
- `src/Shared/ItemDefinitions.luau`

### Gathering resources
- `src/Server/Gathering/Definitions.luau`
- `src/Shared/GatheringNodeIds.luau`
- related item definitions

### Crafting and production
- `src/Server/Crafting/Definitions.luau`
- `docs/PLOT_PROGRESSION.md` when a production station is involved

### Training stations and plots
- `docs/PLOT_PROGRESSION.md`
- `docs/PLOT_TRAINING.md`
- `src/Server/Plots/StationDefinitions.luau`

### Standard enemies and bosses
- `src/Server/Enemies/Definitions.luau`
- `src/Server/Bosses/Definitions.luau`
- current combat and vertical-slice specifications

Resolve before prompting:

- exact asset name and stable gameplay identity where one exists;
- gameplay role;
- region/progression band;
- expected closest and normal viewing distance;
- whether it is static, interactive, equipped, animated, or destructible-looking;
- whether collision is gameplay-relevant;
- whether parts need to remain visibly or mechanically separate;
- whether animation, rigging, attachments, weapon grips, VFX anchors, or hitbox landmarks must be planned before generation;
- whether the asset is a unique model or a reusable family base;
- whether an existing base mesh should be reused rather than generating a new mesh;
- current approved visual traits and exclusions;
- any production standards that are still unresolved.

Discover repository facts before asking the owner. Ask only when missing information would materially change silhouette, family reuse, pose, rig strategy, modularity, or reconstruction method.

## 2. Preserve the Adventurer's Rise visual identity

The project visual progression is:

> **grounded medieval adventure → high fantasy**

The base style is classic medieval adventure. It is not anime-first, dark-fantasy-first, or realism-first.

### Early progression

Favor:

- timber;
- stone;
- practical iron and steel;
- leather and simple cloth where appropriate;
- conventional forests and mines;
- recognizable medieval weapons and tools;
- restrained fantasy embellishment;
- believable construction and material logic.

### Mid progression

Increase:

- runic treatments;
- enchanted materials;
- crystals;
- stronger silhouette hierarchy;
- more ornate but readable construction;
- controlled emissive accents;
- magical attachments and effects where useful.

### Late launch progression

Allow:

- arcane and corrupted structures;
- rare fantasy materials;
- prestigious silhouettes;
- stronger emissive treatment;
- floating or attached magical details where useful;
- more visible magical effects and corruption.

Even late assets must remain readable, performant, and understandable from ordinary Roblox gameplay distances.

### Shared style priorities

All asset prompts should prioritize:

- strong silhouette;
- stylized but believable proportions;
- clear large and medium forms;
- restrained microdetail;
- readable value/material separation;
- low-to-moderate geometric complexity;
- mobile-friendly presentation;
- reusable meshes and asset families;
- progression communicated by silhouette, materials, attachments, emissive accents, and VFX rather than detail density alone.

Avoid excessive filigree, tiny engravings, noisy edge damage, hyper-real material wear, thin fragile geometry, and detail that disappears at normal camera distance.

## 3. Decide whether this is a new mesh at all

Before choosing a Tripo generation method, classify the request as one of:

- **new unique base mesh**
- **reusable family base mesh**
- **variant of an existing family**
- **boss/prestige geometry that justifies unique work**
- **attachment/add-on for an existing base**
- **material/texture/VFX-only progression variant**

Normal progression tiers should aggressively reuse base geometry.

Examples:

- starter sword → normal sword tier variants;
- basic pickaxe → upgraded normal pickaxe variants;
- ore node family;
- six-tier combat training station family;
- Goblin → Goblin-family variants where anatomy supports reuse;
- normal armor and weapon tiers.

A new progression tier is not sufficient reason to create a new mesh.

Prefer progression through:

- material changes;
- texture changes;
- color/tint;
- metallic finish;
- emissive accents;
- runes;
- crystals or modular attachments;
- small silhouette-changing upgrades;
- particles and VFX.

Reserve substantially unique geometry primarily for:

- bosses;
- boss-unique rewards;
- prestige rewards;
- signature late-game assets;
- cases where gameplay readability or role genuinely requires a different silhouette.

Document the reuse decision in the prompt package.

## 4. Reverify Tripo before making platform claims

Tripo models, API features, and Studio controls change. Recheck relevant current official Tripo documentation before relying on a capability.

Current official facts verified on **2026-09-19** include:

- Image-to-model expects a clearly visible subject with minimal occlusion; Tripo recommends a clean background and at least 256 × 256 input resolution.
- Multiview generation uses front/left/back/right views; the front view cannot be omitted, at least two images are required, and all views should depict the same object under consistent lighting.
- The H-series API exposes controls including `face_limit`, `quad`, `smart_low_poly`, `generate_parts`, texture options, seeds, and orientation controls.
- Tripo's `smart_low_poly` option is documented as best suited to simple, non-complex inputs and can fail on complex assets.
- Tripo's P-series is explicitly intended for low-poly generation; current documentation lists P1 and a P2 preview. Do not assume the user's Tripo Studio surface exposes every API model or control.
- Advanced image generation exposes a `t_pose` template/option for character preparation.
- The advanced-image-generation prompt limit is documented as 1,024 characters, approximately 100 words. This limit applies to that image-generation surface and must not be generalized to unrelated prompt fields without verification.
- Tripo's official game-prop guidance recommends the prompt structure:
  `Object + Material + Style + Structural Details`
- Tripo's own game-asset guidance treats generated meshes as starting points that commonly need cleanup, optimization, retopology, scale/pivot work, UV/material review, and engine validation.

When official documentation cannot be verified:

- omit the uncertain feature;
- label it `unverified`; or
- recommend a workflow that does not depend on it.

Never convert remembered Tripo behavior into current fact.

## 5. Choose the input strategy deliberately

Use the smallest method that provides enough control.

### Text-to-3D

Use when:

- the concept is not visually locked;
- the asset has simple, readable construction;
- broad silhouette exploration is useful;
- multiple candidates are expected before choosing one;
- no approved reference image exists.

This is often appropriate for simple environmental props and early pipeline tests.

Base the prompt on Tripo's documented structure:

`Object + Material + Style + Structural Details`

Then add orientation, gameplay scale/readability intent, family reuse intent, and exclusions.

### Image-to-3D

Prefer when:

- the shape language is already approved;
- a concept image captures the desired silhouette;
- material placement matters;
- text-only generations drift stylistically;
- a family base needs consistency.

The reference should present one centered subject, fully visible, on a clean background with even lighting and minimal occlusion.

Do not use a full environment scene as the source for one isolated asset unless an extraction workflow is deliberately being used and has been verified.

### Multiview-to-3D

Prefer when:

- back shape matters;
- thickness matters;
- side silhouette matters;
- tool heads, weapon guards, handles, sockets, layered armor, station geometry, or boss anatomy cannot be inferred safely from one image;
- a single view would cause avoidable reconstruction guesswork.

Use two to four consistent views. Under the current official Tripo multiview contract, front is required. Keep object scale, pose, design, materials, and lighting consistent across all views.

### Character / rig preparation

Use a rig-conscious workflow before generating a character or enemy that must animate.

Use Tripo's current character-preparation/T-pose capability when available and useful, but treat it as an input-preparation aid rather than a rig guarantee.

Do not finalize a character prompt until the project has identified the downstream rig target or has explicitly accepted a prototype rig experiment.

## 6. Build prompts in this order

Write one coherent prompt using this order unless the asset requires a justified exception:

1. **Subject and gameplay role** — exactly what the object is and how it functions in Adventurer's Rise.
2. **Family role** — reusable family base, normal-tier variant, unique boss asset, prestige asset, or attachment.
3. **Pose or orientation** — upright, front-facing, horizontal, planted, T-pose, front three-quarter, orthographic, etc.
4. **Silhouette and proportions** — primary masses, width/height relationship, stance, blade/head/handle ratios, node cluster shape, boss scale cues.
5. **Structural geometry** — only forms that must exist in geometry or remain separable.
6. **Material hierarchy** — broad material regions that should read clearly in Roblox.
7. **Adventurer's Rise style** — grounded medieval or the correct later fantasy escalation, stylized believable forms, strong silhouette, restrained microdetail.
8. **Gameplay readability** — large/medium forms should remain legible at normal gameplay camera distance.
9. **Reference presentation** when generating an image — fully visible, centered, uncropped, plain background, even studio light, minimal shadow.
10. **Exclusions** — likely failure modes and off-style features.

Use precise nouns and measurable form language over vague mood words such as “epic,” “awesome,” “beautiful,” or “super detailed.”

## 7. Category rules

### Weapons

- Determine whether the requested item belongs to an existing weapon family before generating new geometry.
- Prioritize readable blade/head, guard, grip, pommel, and overall length.
- Avoid overly thin guards, spikes, chains, tassels, dangling ornaments, and tiny engraved geometry unless gameplay/status value justifies them.
- For normal tiers, keep the base silhouette stable and plan progression through materials, accents, attachments, and VFX.
- Boss/prestige weapons may use stronger silhouette changes and unique geometry.
- Clearly separate geometry that may need a Roblox attachment, grip point, VFX origin, or modular adornment later.
- Do not claim Tripo will produce a correct Roblox grip, pivot, attachment, or combat hitbox. Those are downstream setup tasks.

### Gathering tools

- Treat normal tool upgrades as families by default.
- Keep the functional head/handle relationship obvious.
- Use believable medieval tool construction in early tiers.
- Avoid decorative complexity that interferes with silhouette or animation.
- Upgrade identity should usually come from better material, reinforcement, head shape refinement, small attachments, runes, or emissive accents rather than an entirely new object every tier.

### Resource nodes

- Build a reusable node family rather than unrelated rocks for every ore.
- The silhouette should read as a gatherable gameplay object, not generic terrain clutter.
- Exposed resource should be visible from several common approach angles.
- Favor broad clustered forms and clear ore/host-rock material separation.
- Avoid hundreds of tiny crystal shards, razor-thin flakes, tiny cavities, or noisy rubble that adds geometry without gameplay readability.
- Do not bake a large terrain base into the source mesh unless the world-placement plan explicitly requires it.
- Preserve room for material/texture swaps and later fantasy attachments across ore tiers.

### Training stations

- Treat each station type as one visual family with escalating tiers.
- Base-tier form should communicate the trained skill immediately.
- Later tiers should reuse the core family and escalate through reinforcement, armor, materials, runes, crystals, magical constructs, attachments, and VFX.
- Geometry should support a fixed plot socket and stable footprint.
- Do not make every station tier a wholly unrelated prop.
- Avoid tiny moving pieces or complex mechanical assemblies unless the interaction design requires them.

### Forge and production stations

- The Forge should read immediately as a medieval Smithing station in the shared hub.
- Favor broad forge body, hearth/fire area, work surface/anvil relationship, chimney/hood where appropriate, and a clean player interaction side.
- Keep components understandable and separable where later animation/VFX/interaction could benefit.
- Avoid clutter piles, loose tools, environment dressing, or a whole blacksmith workshop in a single generated asset unless explicitly requested.
- Personal upgraded stations should remain recognizable descendants of the shared baseline rather than unrelated redesigns.

### Characters and standard enemies

Before generation, resolve whether the model needs animation.

For animated enemies:

- prioritize a clean, readable silhouette;
- use clear anatomy/proportions;
- keep arms separated from the torso;
- keep legs separated from each other;
- maintain visible elbow, knee, shoulder, hip, neck, hand, and foot landmarks;
- minimize unnecessary loose geometry;
- avoid deeply intersecting armor/clothing layers;
- separate weapons/equipment where appropriate;
- use symmetrical neutral pose for base-mesh generation unless an approved rig requires something else;
- keep accessories and silhouette pieces large enough to read from gameplay distance.

The first Goblin is a **character-pipeline prototype**. It should validate style, body proportions, mesh cleanup, rig strategy, animation readiness, import, and gameplay readability before it is accepted as the final Goblin visual standard.

Do not lock a Goblin family around a weak first prototype.

### Bosses

Bosses should visually belong to their enemy family where appropriate while reading immediately as more important and more dangerous.

Use:

- stronger scale or mass;
- clearer silhouette hierarchy;
- upgraded armor/weapons;
- family-consistent anatomy;
- one or two signature shapes;
- restrained but obvious magical/status accents where progression supports them.

Avoid solving “boss” only by adding dozens of spikes, excessive emissive detail, or unrelated visual noise.

For the Goblin Chieftain, prefer a recognizable Goblin-family foundation plus boss-specific scale, armor, weapon, crown/headgear, trophies, or other deliberate status elements rather than a totally different species.

### Architecture and world props

- Generate one dominant prop/module per reconstruction.
- Keep early-world architecture grounded in timber, stone, iron, practical joinery, and readable medieval construction.
- Later regions may introduce runes, crystals, corruption, magical masonry, or impossible details in controlled progression.
- Avoid generating whole scenes when one reusable prop is required.
- Favor modularity and repeatable pieces over one giant unique environment mesh.

## 8. Rig-first character rule

For any asset expected to animate, the prompt package must include a **Rig Preparation** section before generation.

Resolve or explicitly mark unresolved:

- intended Roblox character/rig strategy;
- whether the asset uses a Roblox humanoid rig, custom rig, or a prototype still under evaluation;
- neutral pose;
- limb separation;
- whether armor is skinned with the body or separate;
- whether weapons are separate meshes;
- major attachment/VFX anchor needs;
- whether facial animation is required;
- boss size relationship to the base family.

If the repository has not approved the character rig standard, write:

> **Rig standard: unresolved — prototype only. Do not treat this generation as final production character topology.**

Do not invent an R15/custom skeleton decision.

## 9. Reference-image guidance

When a reference image is useful, specify:

- exact view;
- whether perspective or near-orthographic presentation is preferred;
- full-object framing;
- clean light or neutral background;
- even lighting;
- minimal cast shadow;
- no environment;
- no unrelated props;
- no crop;
- no hidden back/side geometry that matters;
- no pose that causes limbs or parts to touch.

For multiview:

- use the same object;
- same design state;
- same pose;
- same materials;
- consistent lighting;
- consistent approximate scale in frame;
- required front view plus useful side/back views.

Reference art is a geometry/style communication tool, not proof that Tripo will reproduce exact topology or dimensions.

## 10. Roblox downstream requirements

The production path is:

> **Tripo → Blender cleanup/optimization → Roblox Studio → in-game validation**

Current official Roblox documentation confirms that Studio's 3D Importer accepts common third-party 3D formats including FBX and glTF in supported workflows and provides preview/error checking. Exact format choice should follow the current asset type and import workflow.

Roblox performance guidance also favors:

- avoiding unnecessarily expensive precise mesh collision;
- using simpler collision fidelity where appropriate;
- allowing appropriate render-fidelity reduction;
- reusing meshes instead of importing duplicate geometry as unique assets;
- reusing/tinting textures where practical rather than creating redundant texture assets.

These are platform capabilities/guidelines, not substitutes for project-specific budgets.

### Blender cleanup checklist

After Tripo generation, inspect and correct as needed:

- scale;
- orientation;
- pivot/origin;
- transform application;
- silhouette;
- hidden/internal geometry;
- nonmanifold or self-intersecting geometry;
- duplicated or floating fragments;
- accidental fused parts;
- topology flow where deformation matters;
- decimation/retopology where needed;
- UVs;
- texture/material assignment;
- material-slot count;
- normals/smoothing;
- thickness on fragile forms;
- separable parts;
- attachment/VFX anchor planning;
- rig/weights for animated assets;
- collision proxy strategy where applicable.

Do not state that every item must be changed. Inspect first.

### Roblox Studio validation checklist

Validate in Studio:

- import warnings/errors;
- final scale relative to player and nearby world objects;
- orientation and pivot behavior;
- material and texture appearance;
- silhouette at normal gameplay camera distance;
- readability on smaller/mobile screens;
- collision behavior;
- interaction range/position;
- animation deformation where relevant;
- weapon/tool grip and attachment placement where relevant;
- boss and enemy hit/readability;
- VFX anchor locations where relevant;
- visual consistency with neighboring Adventurer's Rise assets;
- client performance in representative scenes.

For repeated family assets, compare the family together rather than validating each tier in isolation.

## 11. Missing production standards rule

The repository currently does **not** establish authoritative project-wide values for all of the following:

- per-category triangle ceilings;
- texture-resolution budgets;
- material-slot limits;
- draw-call targets;
- collision policy by category;
- LOD generation policy;
- final mesh import format convention;
- canonical scale/pivot/orientation convention for every asset category;
- approved character skeleton/rig standard;
- enemy/boss geometry budgets;
- VFX budgets.

Do not fabricate these.

When one of these matters to a prompt or acceptance decision, report it as:

> **Production standard missing — requires owner/technical-art decision before mass production.**

A pipeline-validation batch may collect measurements and inform later standards, but measurements from one candidate are not automatically project policy.

## 12. Pipeline-validation phase

Before mass production, use a small representative batch to validate:

- style consistency;
- Tripo generation quality;
- reusable-family strategy;
- Blender cleanup burden;
- Roblox import reliability;
- gameplay readability;
- collision/interaction setup;
- mobile performance;
- rig/animation workflow for characters;
- boss-family differentiation.

The current vertical slice supports validation around assets such as:

- Iron Ore node;
- starter/upgraded sword family;
- basic/upgraded pickaxe family;
- shared Forge;
- Melee training station;
- Defense training station;
- Goblin;
- Goblin Chieftain.

This list is not permanent. Recheck the current repository before using it.

Do not write all validation prompts at once unless explicitly asked. Work one asset or tightly related family at a time, inspect the result, then iterate.

## 13. Return this exact prompt package

For each asset request, return:

### Asset
State the current repository identity and gameplay role.

### Reuse decision
State one of:

- `new reusable family base`
- `variant of existing base`
- `unique boss/prestige mesh`
- `attachment/add-on`
- `material/texture/VFX-only variant`

Explain the decision briefly.

### Mode
State one of:

- `text-to-3D`
- `image-to-3D`
- `multiview-to-3D`
- `character / T-pose preparation`

Give one sentence explaining the choice.

### Ready-to-paste Tripo prompt
Provide one compact prompt with no commentary inside it.

### Negative prompt
Provide only when the current Tripo surface supports it or when the reference-image generator supports it. Keep it focused on the most likely failures.

### Reference / multiview guidance
State the required view, framing, background, lighting, and whether additional views are needed.

### Structural / rig requirements
List only geometry, separation, attachment, or rig concerns that matter for this asset.

### Production-standard status
State any applicable approved standard. If none exists, explicitly identify the missing standard rather than inventing one.

### What to inspect after generation
Give a short candidate-review checklist specific to the expected Tripo failure modes for this asset.

### Fact status
List any current Tripo or Roblox capability relied upon, official source, verification date, and any unverified assumption.

## 14. Quality gate

Before delivery, confirm:

- current repository decisions were checked;
- one clear asset or tightly related family is being generated;
- the new-mesh/reuse decision is explicit;
- the progression band and fantasy intensity are correct;
- the asset is readable at Roblox gameplay distance;
- large and medium forms are prioritized over microdetail;
- the subject is complete and uncropped in reference guidance;
- structural parts are not hidden or ambiguously described;
- animated characters have explicit limb separation and rig-preparation notes;
- normal progression is not creating unnecessary unique meshes;
- bosses remain related to their family where appropriate;
- no unapproved technical budget was invented;
- no guarantee is made about topology, exact polycount, rigging, cleanup duration, or production readiness;
- downstream Blender and Roblox checks are stated;
- the output package includes asset, reuse decision, mode, prompt, reference guidance, structural requirements, production-standard status, review checks, and fact status.

## 15. Controlled iteration rule

Tripo generation is not deterministic.

When practical:

1. generate several controlled candidates;
2. compare silhouette and proportions first;
3. reject obviously weak geometry early;
4. choose the candidate with the strongest reusable base;
5. revise the prompt around observed failures only;
6. avoid changing several unrelated variables at once;
7. record recurring failure modes that may justify a project prompt pattern or production standard.

Do not spend extensive Blender time rescuing a fundamentally poor generation when another controlled Tripo variation is likely to provide a better source mesh.

When the user supplies screenshots or model renders, evaluate them against:

- Adventurer's Rise visual progression;
- family reuse strategy;
- gameplay readability;
- structural needs;
- rig/animation needs;
- cleanup burden;
- likely Roblox import/runtime concerns.

Do not judge the model only as a standalone render.

## Compact templates

### General reusable prop

> Generate a complete isolated [asset] as a reusable Adventurer's Rise game asset. [Orientation/state]. Use a strong readable silhouette with [major proportions/forms]. Include only [essential structural geometry]. Materials: [broad material regions]. Style: stylized believable medieval fantasy, grounded for this progression tier, clear large and medium forms, restrained microdetail, low-to-moderate geometric complexity, readable from normal Roblox gameplay distance. Fully visible and uncropped. No environment, extra props, branding, text, thin fragile details, or unnecessary surface noise.

### Resource-node family base

> Generate a complete isolated [resource] mining node as a reusable Adventurer's Rise ore-node family base. Broad clustered rock silhouette with several large exposed [ore] deposits visible from multiple approach angles. Clear separation between host stone and ore material. Stylized believable medieval-fantasy game asset, strong chunky forms, restrained facets, minimal rubble, low-to-moderate geometric complexity, readable from normal Roblox gameplay distance. No terrain slab, cave wall, tools, crystals unrelated to this tier, tiny shards, deep noisy cavities, text, or environment.

### Rig-conscious enemy base

> Generate a complete full-body [enemy] base character for an animated Roblox game enemy. Symmetrical neutral T-pose, upright torso and head facing forward, arms extended with clear space from the torso, elbows and knees readable, legs separated, hands and feet fully visible, clean shoulder/hip/neck landmarks. [Approved body proportions and family traits]. Keep equipment separate where practical. Adventurer's Rise style: stylized believable medieval fantasy, strong silhouette, readable anatomy, restrained detail, no anime exaggeration, no dark-horror distortion, no loose dangling clutter. Plain neutral background, even lighting, no cropped parts.

## Official evidence to recheck

### Tripo

Reverify before use:

- Image to 3D Model:
  `https://developers.tripo3d.ai/en/docs/generation-image-to-model`
- Multiview to 3D Model:
  `https://developers.tripo3d.ai/en/docs/generation-multiview-to-model/standard`
- Text to 3D Model:
  `https://developers.tripo3d.ai/en/docs/generation-text-to-model/standard`
- P-series image-to-model:
  `https://developers.tripo3d.ai/en/docs/generation-image-to-model/p`
- Advanced image generation / T-pose:
  `https://docs.tripo3d.ai/image-generation/advanced-image-generation.html`
- Official Tripo game-prop workflow:
  `https://www.tripo3d.ai/blog/ai-3d-props-for-games`

API documentation is authoritative for API-exposed parameters. Tripo blog/education content is useful official workflow guidance but does not prove that the same controls exist in the Studio UI.

### Roblox

Reverify relevant engine/import/performance claims through current Roblox Creator Hub documentation, including:

- Studio 3D Importer / rigid import workflows:
  `https://create.roblox.com/docs/art/accessories/creating-rigid/importing`
- Performance optimization:
  `https://create.roblox.com/docs/performance-optimization/improve`
- Avatar/character import workflows when character setup is relevant:
  `https://create.roblox.com/docs/avatar-setup/auto-setup`

## Maintenance and invalidation

Review this skill after material changes to:

- Adventurer's Rise art direction;
- the vertical slice;
- equipment family policy;
- enemy/boss family direction;
- gathering or crafting content;
- player plot/station progression;
- approved technical art standards;
- character rig strategy;
- Tripo Studio/API generation, low-poly, multiview, T-pose, rigging, segmentation, or export behavior;
- Roblox import, mesh, material, collision, character, or performance guidance;
- the Tripo → Blender → Roblox Studio workflow.

Disable or revise any instruction that cannot be supported by current official platform evidence or current repository authority.
