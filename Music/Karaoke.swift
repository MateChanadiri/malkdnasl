import AVFoundation
import AudioToolbox

/// Real karaoke: removes whatever is panned dead centre (the lead vocal) from a stereo mix, while the bass stays.
/// An in-process audio unit, so it sits in the engine graph like any other effect.
nonisolated final class KaraokeUnit: AUAudioUnit, @unchecked Sendable {
    nonisolated static let unitDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x6B617261, componentManufacturer: 0x4D75736B,
        componentFlags: 0, componentFlagsMask: 0)

    private nonisolated(unsafe) static var registered = false

    /// Registers the unit once and returns an engine node for it.
    static func makeNode() -> AVAudioUnitEffect {
        if !registered {
            AUAudioUnit.registerSubclass(KaraokeUnit.self, as: unitDescription, name: "Music: Karaoke", version: 1)
            registered = true
        }
        return AVAudioUnitEffect(audioComponentDescription: unitDescription)
    }

    /// 0 leaves the song alone, 1 removes the centre as far as it goes.
    var amount: Float {
        get { state[0] }
        set { state[0] = min(max(newValue, 0), 1) }
    }

    // [0] amount, [1] low-pass memory at 170 Hz (the bass that is kept), [2] low-pass memory at 6 kHz (the highs that are kept)
    private let state: UnsafeMutablePointer<Float>
    private var inBus: AUAudioUnitBus
    private var outBus: AUAudioUnitBus
    private var inArray: AUAudioUnitBusArray!
    private var outArray: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        inBus = try AUAudioUnitBus(format: format)
        outBus = try AUAudioUnitBus(format: format)
        state = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        state.initialize(repeating: 0, count: 4)
        try super.init(componentDescription: componentDescription, options: options)
        inArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        outArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
        maximumFramesToRender = 4096
    }

    deinit { state.deallocate() }

    override var inputBusses: AUAudioUnitBusArray { inArray }
    override var outputBusses: AUAudioUnitBusArray { outArray }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self.state
        let outBus = self.outBus
        return { actionFlags, timestamp, frameCount, _, outputData, _, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            let status = pullInput(actionFlags, timestamp, frameCount, 0, outputData)
            if status != noErr { return status }

            let target = state[0]
            let list = UnsafeMutableAudioBufferListPointer(outputData)
            var amount = state[3]
            guard target > 0.002 || amount > 0.002, list.count >= 2,
                  let lp = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let rp = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            // Only the voice range is taken out of the centre (about 170 Hz to 6 kHz). The bass and the cymbals stay
            // untouched, which is what keeps the rest of the song from sounding hollow.
            let rate = Float(outBus.format.sampleRate > 0 ? outBus.format.sampleRate : 44100)
            let kLow: Float = 1 - exp(-2 * Float.pi * 170 / rate)
            let kHigh: Float = 1 - exp(-2 * Float.pi * 6000 / rate)
            var low = state[1]
            var high = state[2]
            for i in 0..<Int(frameCount) {
                let mid = (lp[i] + rp[i]) * 0.5
                low += kLow * (mid - low)
                high += kHigh * ((mid - low) - high)
                // The level glides to its new value, so moving the slider never clicks.
                amount += (target - amount) * 0.0015
                let voice = high * amount
                lp[i] -= voice
                rp[i] -= voice
            }
            state[2] = high
            state[3] = amount
            state[1] = low
            return noErr
        }
    }
}
