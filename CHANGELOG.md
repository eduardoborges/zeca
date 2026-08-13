# Changelog

## [1.3.0](https://github.com/eduardoborges/zeca/compare/v1.2.0...v1.3.0) (2026-08-13)


### Features

* **brand:** finish the rename, ZecaAI becomes Zeca everywhere ([64fa351](https://github.com/eduardoborges/zeca/commit/64fa351073b8595d84b5787bc0ef8feefc60f2ae))
* **brand:** rename Zeca AI to Zeca ([67bc4e6](https://github.com/eduardoborges/zeca/commit/67bc4e62fd8101fb4c97f5208fca813eb55513df))
* **icon:** add app icon and enhance README with project description and features ([816c68b](https://github.com/eduardoborges/zeca/commit/816c68bf72b40ee7086aabf5db0d7fd4faa5cf13))
* **meetings:** export and import meetings as .zeca archives ([615b682](https://github.com/eduardoborges/zeca/commit/615b682c9a6dcf13989a29cc7ec586dd12a39447))
* **onboarding:** provider choice, inline downloads and support step ([b8a2272](https://github.com/eduardoborges/zeca/commit/b8a22721e07ba657c01ed2124bff2a9b7c072572))
* **readme:** update title with emoji and refine description for clarity ([8eb58dc](https://github.com/eduardoborges/zeca/commit/8eb58dcd6ebdd2c83e2fd09216e2438a6a76c915))
* **recording:** simplify the live screen and warn about split audio routes ([c24030e](https://github.com/eduardoborges/zeca/commit/c24030ea0c54942e46fed12ba401fe459637ec9c))
* **release:** sign with Developer ID and notarize when secrets exist ([819df99](https://github.com/eduardoborges/zeca/commit/819df99c9529b816fd763e285aa7a7a4c4367b88))
* **summary:** Claude Code CLI as a summary provider ([310dd4b](https://github.com/eduardoborges/zeca/commit/310dd4b8cf16e87dd51d6e709c9ee0cb3b802700))


### Bug Fixes

* **transcript:** show transcription errors in the conversation card ([9fb8138](https://github.com/eduardoborges/zeca/commit/9fb813807afcdb953248c1cef3765ec5a99554aa))

## [1.2.0](https://github.com/eduardoborges/zeca/compare/v1.1.0...v1.2.0) (2026-08-11)


### Features

* **meetings:** create a meeting from a pasted transcript ([fc5a5bd](https://github.com/eduardoborges/zeca/commit/fc5a5bd093ad797ae5808e896727bc6ffefc3fb8))

## [1.1.0](https://github.com/eduardoborges/zeca/compare/v1.0.0...v1.1.0) (2026-08-02)


### Features

* **ui:** banner when screen-recording or microphone access is missing ([7436e55](https://github.com/eduardoborges/zeca/commit/7436e5591002d1eb444e8c53cf937146771463d0))


### Bug Fixes

* **mic:** extract the processed voice channel by hand ([d615f7d](https://github.com/eduardoborges/zeca/commit/d615f7df544c750d0b4a64c61d98bb5de4e25238))

## [1.0.0](https://github.com/eduardoborges/zeca/compare/v0.1.0...v1.0.0) (2026-08-02)


### ⚠ BREAKING CHANGES

* **models:** curate the on-device catalog down to five
* **settings:** transcription always auto-detects the language
* **transcript:** drop speaker diarization, keep You/Others

### Features

* **ai:** on-device summaries, point-by-point notes and translation ([35557c2](https://github.com/eduardoborges/zeca/commit/35557c2e38f5d8dbccf0efb1e83f735f4630eec6))
* **app:** menu bar item with recording status ([40f3f32](https://github.com/eduardoborges/zeca/commit/40f3f32916a2ae529bce0cc686feaad08c61100a))
* **app:** notify when processing ends with the app in the background ([904b01f](https://github.com/eduardoborges/zeca/commit/904b01fd6a2c280e1153b0e6ceaf7f630a15987a))
* **assets:** vector app icon from hand-traced SVG ([644f2ff](https://github.com/eduardoborges/zeca/commit/644f2ff4068b5c1bf0cd702ba573d6b12bd3d0b1))
* **calendar:** Google Calendar integration ([40e4537](https://github.com/eduardoborges/zeca/commit/40e4537e1cfe8d237d88e0c6e12a57a60d95240c))
* **models:** curate the on-device catalog down to five ([fbfd4ec](https://github.com/eduardoborges/zeca/commit/fbfd4ecfe630e5925d5d7201df2851ee832ee7f2))
* **playback:** real player card and combined meeting mix ([85fccc1](https://github.com/eduardoborges/zeca/commit/85fccc176c9ae3266249627d1b14e981dc8ea149))
* **recorder:** automatic titles, deletion and menu bar timer ([4c5ca2c](https://github.com/eduardoborges/zeca/commit/4c5ca2c7609a6bf838e6a948f01c398b074e0628))
* **release:** package the app as a DMG ([ca36237](https://github.com/eduardoborges/zeca/commit/ca362373afef8a44a40d919f65f74eeb95e0191b))
* **settings:** custom-server toggle for the OpenAI provider ([c141ce3](https://github.com/eduardoborges/zeca/commit/c141ce3a5bcc5ee4135adfeb394bb2666b82e52f))
* **settings:** fetch available models from the OpenAI-compatible server ([005cbe5](https://github.com/eduardoborges/zeca/commit/005cbe519810a4a4f5208c5b1059e4ac8fa83ea8))
* **settings:** full download controls for the on-device model ([4a721f6](https://github.com/eduardoborges/zeca/commit/4a721f6339dee7d0b7ebd539da4a403aca1eb109))
* **settings:** group providers by type with on-device first ([ea027be](https://github.com/eduardoborges/zeca/commit/ea027bec6f524125a3b1d40d5622ef8b9e9a7d67))
* **settings:** sidebar-tab settings window ([ade8939](https://github.com/eduardoborges/zeca/commit/ade8939cb6577c565395f3ead3e99279377e597f))
* **settings:** transcription always auto-detects the language ([2d0d38d](https://github.com/eduardoborges/zeca/commit/2d0d38dc4a193e06d7f79bf1e5864454b3a9bcca))
* **settings:** unified single-page settings and on-device model catalog ([29482d1](https://github.com/eduardoborges/zeca/commit/29482d13178da1218e39542898c0f2aac7baf642))
* **sidebar:** multi-select with batch delete, Enter renames, Cmd+Backspace deletes ([c76930e](https://github.com/eduardoborges/zeca/commit/c76930ebb244168f812359bc378425b478dfbd71))
* **site:** agent-ready discovery files ([b319633](https://github.com/eduardoborges/zeca/commit/b319633c2864d8d37f2525668b3b54889ed2e076))
* **site:** English copy, vector logo, Apple nav and scroll animations ([a8118da](https://github.com/eduardoborges/zeca/commit/a8118da6f03d74c38eeb15f94777733375465984))
* **summary:** Bonsai ternary models in the catalog ([21be29d](https://github.com/eduardoborges/zeca/commit/21be29d110c7537ad119b0c3214e481b7085c7ea))
* **summary:** byte-accurate model download progress ([7903b54](https://github.com/eduardoborges/zeca/commit/7903b54f0ac646584def488c62fa9414052f1b0a))
* **summary:** embedded on-device LLM provider (Qwen 3 via MLX) ([cc5d612](https://github.com/eduardoborges/zeca/commit/cc5d6126339f39c6b4940e72b68c0c1ec2f99601))
* **summary:** Gemma 4 in the on-device catalog ([c644a75](https://github.com/eduardoborges/zeca/commit/c644a7568e7d47419d2e48e6303d883039366b4d))
* **summary:** let the user pick the Claude model ([198bf1d](https://github.com/eduardoborges/zeca/commit/198bf1d3bb8eb47b73d9bababdeecc8eb9d8c116))
* **summary:** move the catalog to Qwen 3.5 ([e920725](https://github.com/eduardoborges/zeca/commit/e920725e20e4e0696b582af95920d8a2482ae3be))
* **summary:** NVIDIA Nemotron models in the catalog ([19dd396](https://github.com/eduardoborges/zeca/commit/19dd3968ea20be507663d52e7f792582336acaf4))
* **summary:** OpenAI-compatible provider with custom base URL ([a699269](https://github.com/eduardoborges/zeca/commit/a6992699d0bfc76bb3573781ed38e5b0b5735cbd))
* **summary:** restart-download button and honest download progress ([715aa5c](https://github.com/eduardoborges/zeca/commit/715aa5c810546fab326109c99300418d591c3544))
* **summary:** show live thinking from reasoning models ([6e4f052](https://github.com/eduardoborges/zeca/commit/6e4f052353393e42c4bb52a07bbbb9a67deed9e4))
* **summary:** stream the generation live in the cards ([76aec83](https://github.com/eduardoborges/zeca/commit/76aec838157fc913a70e2392c308b2f31e230d8b))
* **summary:** three more popular models in the catalog ([0dbb477](https://github.com/eduardoborges/zeca/commit/0dbb477697400f975d4bf3e8984ac71c2ee84ad4))
* **transcript:** drop speaker diarization, keep You/Others ([792b641](https://github.com/eduardoborges/zeca/commit/792b64177946987f5a59e74963c89d5a66bfffa7))
* **transcription:** Parakeet-only pipeline with English UI ([50056aa](https://github.com/eduardoborges/zeca/commit/50056aa156e5e84403452894778b91c9fc0af8ad))
* **ui:** cancel button for summary and point-by-point generation ([88aafde](https://github.com/eduardoborges/zeca/commit/88aafde51ebb79d2d71e98c6170fbd31579052e6))
* **ui:** monochrome Apple-style theme with Liquid Glass helpers ([da809ea](https://github.com/eduardoborges/zeca/commit/da809ea54928eedb8d3955b48e7c3e2f80c6209b))
* **ui:** redesigned meeting detail, grouped sidebar and English copy ([48408de](https://github.com/eduardoborges/zeca/commit/48408de2262b3d9fd1a01db5f6e90c87f4568383))


### Bug Fixes

* **audio:** cancel speaker echo from the mic track ([6dc18cf](https://github.com/eduardoborges/zeca/commit/6dc18cfb48627356ac8a0ff19ad89e54b6187f3e))
* **live:** raw real-time speech level bars ([f826246](https://github.com/eduardoborges/zeca/commit/f826246d371cf5058b26f5662b849bde9dd60811))
* **recorder:** clean up correctly on failed starts and one-sided captures ([f2d3182](https://github.com/eduardoborges/zeca/commit/f2d3182e67ba289c7558cffd46b6341baef9afeb))
* **summary:** stop the prompt from inventing task owners ([4f033c9](https://github.com/eduardoborges/zeca/commit/4f033c9af9d43a6ec381c8be52647c60244d8e66))
* **summary:** strip &lt;think&gt; blocks from on-device model output ([d061e75](https://github.com/eduardoborges/zeca/commit/d061e75a5daad6716271e25c3675395df18a6419))
* **summary:** tame thinking small models (Qwen 1.7B) ([1edd867](https://github.com/eduardoborges/zeca/commit/1edd867b2be43c39612357ab6efef4e1bae499a3))
* **ui:** keep the summary visible while notes generate ([cfa889d](https://github.com/eduardoborges/zeca/commit/cfa889d90181274f80a194d433b9d4dc5b2f494a))


### Performance Improvements

* **on-device:** turn off model thinking for summaries ([b61adc7](https://github.com/eduardoborges/zeca/commit/b61adc7c01a0d31ef69107302b2010f3b5f9271b))
