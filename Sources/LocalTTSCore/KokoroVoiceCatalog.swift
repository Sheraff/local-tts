import Foundation

public enum KokoroVoiceCatalog {
    public static let englishVoices: [SpeechVoice] = [
        SpeechVoice(id: "af_heart", name: "Heart", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_alloy", name: "Alloy", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_aoede", name: "Aoede", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_bella", name: "Bella", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_jessica", name: "Jessica", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_kore", name: "Kore", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_nicole", name: "Nicole", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_nova", name: "Nova", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_river", name: "River", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_sarah", name: "Sarah", language: "English US", detail: "American female"),
        SpeechVoice(id: "af_sky", name: "Sky", language: "English US", detail: "American female"),
        SpeechVoice(id: "am_adam", name: "Adam", language: "English US", detail: "American male"),
        SpeechVoice(id: "am_echo", name: "Echo", language: "English US", detail: "American male"),
        SpeechVoice(id: "am_eric", name: "Eric", language: "English US", detail: "American male"),
        SpeechVoice(id: "am_fenrir", name: "Fenrir", language: "English US", detail: "American male"),
        SpeechVoice(id: "am_liam", name: "Liam", language: "English US", detail: "American male"),
        SpeechVoice(id: "am_michael", name: "Michael", language: "English US", detail: "American male"),
        SpeechVoice(id: "am_onyx", name: "Onyx", language: "English US", detail: "American male"),
        SpeechVoice(id: "am_puck", name: "Puck", language: "English US", detail: "American male"),
        SpeechVoice(id: "am_santa", name: "Santa", language: "English US", detail: "American male"),
        SpeechVoice(id: "bf_alice", name: "Alice", language: "English UK", detail: "British female"),
        SpeechVoice(id: "bf_emma", name: "Emma", language: "English UK", detail: "British female"),
        SpeechVoice(id: "bf_isabella", name: "Isabella", language: "English UK", detail: "British female"),
        SpeechVoice(id: "bf_lily", name: "Lily", language: "English UK", detail: "British female"),
        SpeechVoice(id: "bm_daniel", name: "Daniel", language: "English UK", detail: "British male"),
        SpeechVoice(id: "bm_fable", name: "Fable", language: "English UK", detail: "British male"),
        SpeechVoice(id: "bm_george", name: "George", language: "English UK", detail: "British male"),
        SpeechVoice(id: "bm_lewis", name: "Lewis", language: "English UK", detail: "British male"),
    ]

    public static let englishVoiceIDs = Set(englishVoices.map(\.id))
}
