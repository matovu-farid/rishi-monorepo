/**
 * Web Audio API thinking indicator sound.
 * Plays a soft, rhythmic sine wave to indicate AI is processing.
 */
let audioContext: AudioContext | null = null;
let intervalId: ReturnType<typeof setInterval> | null = null;

function getAudioContext(): AudioContext {
  if (!audioContext) audioContext = new AudioContext();
  if (audioContext.state === "suspended") audioContext.resume();
  return audioContext;
}

export function startThinkingSound(): void {
  if (intervalId) return;
  const ctx = getAudioContext();

  intervalId = setInterval(() => {
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = "sine";
    osc.frequency.value = 660;
    gain.gain.value = 0.08;
    gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.12);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(ctx.currentTime);
    osc.stop(ctx.currentTime + 0.12);
  }, 600);
}

export function stopThinkingSound(): void {
  if (intervalId) {
    clearInterval(intervalId);
    intervalId = null;
  }
}
