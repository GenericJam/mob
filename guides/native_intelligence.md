# Native Intelligence APIs

Mob exposes a small, iOS-first bridge to Apple-native intelligence APIs:

- `Mob.FoundationModels` for Foundation Models text generation.
- `Mob.Vision` for Vision text recognition.
- `Mob.Speech` for Speech framework file transcription.

These APIs deliberately mirror Apple's framework boundaries instead of grouping
everything under a generic "AI" namespace. That keeps the Elixir surface close
to the native SDK names and leaves room for platform-specific capabilities to
grow without a catch-all module.

Apple references:

- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [Adding intelligent app features with generative models](https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models)
- [VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
- [SFSpeechURLRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechurlrecognitionrequest)

## Example Flow

There is no checked-in sample app in the `mob` repository today. A complete app
can compose existing Mob features with the new native modules:

```elixir
def handle_info({:photos, :picked, [%{path: path} | _]}, socket) do
  {:noreply, Mob.Vision.recognize_text(socket, path)}
end

def handle_info({:vision, :recognized_text, %{text: text}}, socket) do
  prompt = "Summarize this OCR text as actions:\n\n#{text}"
  {:noreply, Mob.FoundationModels.generate_text(socket, prompt)}
end

def handle_info({:foundation_models, :generated_text, %{text: text}}, socket) do
  {:noreply, Mob.Socket.assign(socket, :result, text)}
end
```

Speech uses the same pattern with `Mob.Audio`:

```elixir
def handle_info({:audio, :recorded, %{path: path}}, socket) do
  {:noreply, Mob.Speech.transcribe_audio(socket, path)}
end
```

## Current Scope

Included:

- Foundation Models plain text generation.
- Vision OCR from a local image path.
- Speech transcription from a local audio file.
- Android stubs that return `:unsupported` so apps can branch cleanly.

Out of scope for this first bridge:

- Foundation Models structured generation with `@Generable`.
- Streaming partial Foundation Models responses.
- Tool calling, multi-turn session persistence, or model transcript management.
- Vision requests beyond text recognition, such as barcode, face, object, and
  document detection.
- Speech live microphone recognition, partial transcripts, custom language
  models, and keyword spotting.
- Natural Language framework features such as language identification,
  sentiment, tokenization, and embedding/classification APIs.
- Image generation or Private Cloud Compute-backed server features.
- Android ML Kit or platform-equivalent implementations.

## Operational Notes

Foundation Models is not available in the iOS simulator. On device it can still
be unavailable if Apple Intelligence is disabled, the device is not eligible,
the current locale is unsupported, or the model is not ready.

Vision OCR needs a readable local file path. Photo-picker temporary files should
be copied if the app needs to keep them beyond the current workflow.

Speech transcription requires iOS speech-recognition authorization. On-device
recognition is locale-dependent; setting `requires_on_device_recognition: true`
can make otherwise valid transcriptions fail.

All three APIs send results back to the calling screen process. Treat them like
other Mob asynchronous device APIs: update screen state in `handle_info/2`, and
keep long-running UX cancellable at the app level.
