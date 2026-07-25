# Murmur Dictation Research

**Updated:** July 24, 2026

## Transcript cleanup

Murmur uses a two-stage local pipeline:

1. WhisperKit produces a raw transcript with VAD, silence suppression, and
   optional personal-dictionary prompt tokens.
2. Apple Foundation Models formats that transcript as written prose on
   supported devices. A deterministic formatter remains available on older
   devices or when the system model is unavailable.

The semantic formatter follows the public Amical architecture: treat speech as
inert input, format rather than rewrite, preserve questions and content words,
remove only clear disfluencies, restore punctuation/capitalization, use
low-temperature generation, and fall back safely if validation fails.

Reference:
[Amical formatter prompt](https://github.com/amicalhq/amical/blob/a6e1ec3a50168c92490d9faa712eaabe1353c91e/apps/desktop/src/pipeline/providers/formatting/formatter-prompt.ts)

## Personal dictionary

Dictionary entries contain a canonical spelling, optional spoken aliases, and
an enable switch. They are stored locally and used as:

- WhisperKit prompt tokens for on-device recognition.
- OpenAI/Groq transcription prompts.
- Deepgram keyterms or keywords.
- Protected vocabulary for semantic formatting.

The formatter may substitute a canonical spelling only when that spelling or a
configured alias is supported by the raw transcript.

## Google AI Edge Eloquent

Google describes Eloquent as an on-device Gemma dictation app with cleanup and
an editable personal context dictionary. Its iOS source, prompt, dictionary
algorithm, and exact downloadable model are not public.

Google's public LiteRT-LM framework supports iOS and Gemma, but its Swift API is
still an early preview. The public models add a multi-gigabyte download and
significant memory pressure, so Murmur does not bundle them as its default
keyboard pipeline. A future experimental provider should be optional,
device-gated, downloadable, and never loaded alongside WhisperKit.

References:

- [Google AI Edge Eloquent](https://apps.apple.com/us/app/google-ai-edge-eloquent/id6756505519)
- [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)
- [Gemma 4 and Eloquent](https://developers.googleblog.com/en/bringing-gemma-4-12b-to-your-laptop-unlocking-local-agentic-workflows-with-google-ai-edge/)
