# Test audio (16 kHz mono PCM16)

Generated with macOS `say` (Samantha = A, Daniel = B, Piya = Bangla) and ffmpeg; 0.8 s silences between clips.

- `two_speakers_en.wav` (25.7 s): A, B, A, B
  - A: "Hi, thanks for joining the call. I wanted to talk about the research idea on speech recognition for low resource languages."
  - B: "Sure. I think the key question is whether we can fine tune a multilingual model with only a few hours of Bangla data."
  - A: "Right. We could also try data augmentation and pseudo labeling from unlabeled recordings."
  - B: "That makes sense. Let's write down the plan and meet again next week."
- `bangla.wav` (15.7 s): "আমি আজকে একটা নতুন গবেষণার আইডিয়া নিয়ে কথা বলতে চাই। আমরা বাংলা ভাষার জন্য একটি স্পিচ রিকগনিশন মডেল তৈরি করব। এই প্রজেক্টে আমাদের প্রথম কাজ হবে ডেটাসেট সংগ্রহ করা, তারপর মডেল ট্রেনিং।"
- `mixed_bn_en.wav` (31.3 s): bn1 (first two Bangla sentences), A's first line, bn2 (third Bangla sentence), B's first line.
- Single clips: `a1 a2 b1 b2 bn1 bn2 .wav`, `sil.wav` (0.8 s silence).
