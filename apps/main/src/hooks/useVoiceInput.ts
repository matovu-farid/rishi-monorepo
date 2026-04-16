import { useState, useRef, useCallback, useEffect } from 'react';
import { getAuthToken } from '@/modules/auth';

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev';

interface UseVoiceInputReturn {
  isRecording: boolean;
  duration: number;
  error: string | null;
  startRecording: () => Promise<void>;
  stopRecording: () => Promise<string>;
}

export function useVoiceInput(): UseVoiceInputReturn {
  const [isRecording, setIsRecording] = useState(false);
  const [duration, setDuration] = useState(0);
  const [error, setError] = useState<string | null>(null);

  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const mimeTypeRef = useRef<string>('audio/webm');

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (recorderRef.current && recorderRef.current.state !== 'inactive') {
        recorderRef.current.stop();
      }
      if (streamRef.current) {
        streamRef.current.getTracks().forEach((t) => t.stop());
      }
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
      }
    };
  }, []);

  const startRecording = useCallback(async () => {
    setError(null);

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;

      // Choose MIME type
      const preferredMime = 'audio/webm;codecs=opus';
      const mimeType = MediaRecorder.isTypeSupported(preferredMime)
        ? preferredMime
        : 'audio/webm';
      mimeTypeRef.current = mimeType;

      chunksRef.current = [];
      const recorder = new MediaRecorder(stream, { mimeType });
      recorderRef.current = recorder;

      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) {
          chunksRef.current.push(e.data);
        }
      };

      recorder.start();
      setIsRecording(true);
      setDuration(0);

      // Duration timer
      intervalRef.current = setInterval(() => {
        setDuration((prev) => prev + 1);
      }, 1000);
    } catch (err) {
      console.error('[useVoiceInput] startRecording failed:', err);
      setError('Could not access microphone. Check browser permissions.');
    }
  }, []);

  const stopRecording = useCallback((): Promise<string> => {
    return new Promise<string>((resolve, reject) => {
      const recorder = recorderRef.current;
      if (!recorder || recorder.state === 'inactive') {
        resolve('');
        return;
      }

      // Clear duration timer
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }

      recorder.onstop = async () => {
        // Stop all stream tracks
        if (streamRef.current) {
          streamRef.current.getTracks().forEach((t) => t.stop());
          streamRef.current = null;
        }

        setIsRecording(false);
        setDuration(0);

        // Create blob from chunks
        const blob = new Blob(chunksRef.current, { type: mimeTypeRef.current });
        chunksRef.current = [];

        try {
          // POST to Worker STT endpoint
          const token = await getAuthToken();
          const response = await fetch(`${WORKER_URL}/api/audio/transcribe`, {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${token}`,
              'Content-Type': mimeTypeRef.current,
            },
            body: blob,
          });

          if (!response.ok) {
            throw new Error(`Transcription failed: ${response.status}`);
          }

          const data = await response.json() as { transcript: string };
          resolve(data.transcript);
        } catch (err) {
          console.error('[useVoiceInput] transcription failed:', err);
          setError('Voice transcription failed. Please try again.');
          reject(err);
        }
      };

      recorder.stop();
    });
  }, []);

  return { isRecording, duration, error, startRecording, stopRecording };
}
