# Audio Error Debugging Guide

## Overview

This document explains the comprehensive logging and error management improvements added to help identify audio playback issues in the TTS (Text-to-Speech) system.

## Changes Made

### 1. Player.ts - Enhanced Audio Error Handling

#### Error Handler Improvements

- **Detailed MediaError Information**: Now captures and logs the specific media error code with human-readable names:
  - `MEDIA_ERR_ABORTED` (1) - Playback aborted by user
  - `MEDIA_ERR_NETWORK` (2) - Network error while loading
  - `MEDIA_ERR_DECODE` (3) - Decode error (corrupted or unsupported format)
  - `MEDIA_ERR_SRC_NOT_SUPPORTED` (4) - Media source not supported

#### Audio Element State Logging

Now logs comprehensive audio element state information:

- `src` - The audio file URL being played
- `currentTime` - Current playback position
- `duration` - Total audio duration
- `readyState` - How much of the media is ready:
  - `HAVE_NOTHING` (0) - No information available
  - `HAVE_METADATA` (1) - Metadata loaded
  - `HAVE_CURRENT_DATA` (2) - Current frame available
  - `HAVE_FUTURE_DATA` (3) - Future data available
  - `HAVE_ENOUGH_DATA` (4) - Enough data to play
- `networkState` - Network state of the media:
  - `NETWORK_EMPTY` (0) - No data loaded
  - `NETWORK_IDLE` (1) - Media selected but not loading
  - `NETWORK_LOADING` (2) - Currently loading data
  - `NETWORK_NO_SOURCE` (3) - No valid source found

#### Context Information

Each error now includes:

- Current paragraph index
- Text preview (first 100 characters)
- CFI range for the paragraph
- Timestamp of when the error occurred

### 2. TTS Queue (ttsQueue.ts) - Enhanced API Communication Logging

#### Request Logging

- Request URL and configuration
- Request body size
- Text length and preview
- Priority and retry count

#### Response Logging

- HTTP status code and status text
- Response headers
- Buffer size received
- Error text from failed API responses

#### Error Detection

- Empty buffer detection
- Non-OK HTTP status detection
- Detailed error stack traces

### 3. TTS Service (ttsService.ts) - Request Flow Tracking

#### Request Tracking

- Request ID generation and tracking
- Active request detection
- Cache hit/miss logging
- Request completion tracking

#### Error Logging

- Text length and preview
- Priority information
- Detailed error objects with name, message, and stack trace

### 4. TTS Cache (ttsCache.ts) - File System Operations Logging

#### File Path Generation

- Book cache directory status
- Directory creation logging
- Hashed CFI values
- Generated file paths

#### File Operations

- File existence checks
- File stats (size, modification time)
- Write operation tracking
- File verification after write
- Size mismatch detection
- Empty file detection

## How to Use This Logging for Debugging

### Step 1: Reproduce the Error

Play audio until you encounter the error at a specific text passage.

### Step 2: Use the Error Info Button (NEW!)

When an error occurs, you'll see:

1. A red **AlertTriangle** icon in the TTS controls
2. A small **Info** button (ℹ️) next to the alert icon

**Click the Info button** to:

- Log detailed error information to the console
- See a summary toast notification
- Get structured error data including:
  - All error messages
  - Audio element state (ready state, network state, media error)
  - Current playback state (paragraph index, playing state)
  - Cache information

### Step 3: Check Console Output

Look for error markers:

- 🔴 **Red circle** - Critical errors
- ✅ **Green checkmark** - Successful operations
- ▶️ **Play button** - Playback events
- > > > **Arrows** - Service/Queue/Cache operations
- 📊 **Chart** - Detailed error information (from UI button)

### Step 3: Analyze the Error Flow

#### A. Audio Load Errors (Player.ts:237)

Look for: `🔴 Audio load error - Full details:`

Key information to check:

```javascript
{
  eventType: "error",
  src: "asset://localhost/path/to/audio.mp3", // Check if path is valid
  readyState: 0, // Check state name
  networkState: 3, // Check state name
  mediaError: {
    code: 3, // Look for the error name
    message: "...",
    errorName: "MEDIA_ERR_DECODE - Decode error..."
  },
  currentParagraph: {
    index: 42,
    text: "The problematic text...",
    cfiRange: "/6/4[...]"
  }
}
```

**Common Issues:**

- **MEDIA_ERR_DECODE**: Audio file is corrupted or invalid MP3
- **MEDIA_ERR_NETWORK**: File not found or access denied
- **MEDIA_ERR_SRC_NOT_SUPPORTED**: Invalid file path or unsupported format
- **readyState: 0 (HAVE_NOTHING)**: File never loaded
- **networkState: 3 (NETWORK_NO_SOURCE)**: Source URL is invalid

#### B. Audio Playback Errors (Player.ts:152)

Look for: `🔴 Audio playback error - Full details:`

Similar structure to load errors, but occurs during playback.

#### C. API Generation Errors

Look for: `>>> Queue: Audio generation failed`

Key information:

```javascript
{
  requestId: "bookId-cfiRange",
  url: "http://localhost:5000/v1/audio/speech",
  textLength: 523,
  textPreview: "The text that failed...",
  retryCount: 0,
  error: {
    name: "Error",
    message: "OpenAI TTS API error: 500 Internal Server Error",
    stack: "..."
  }
}
```

**Common Issues:**

- **Network errors**: TTS API server is down or unreachable
- **Empty buffer**: API returned 0 bytes
- **Non-OK status**: API returned error status (400, 500, etc.)

#### D. Cache Errors

Look for: `>>> Cache: Failed to save cached audio`

Key information:

```javascript
{
  bookId: "book123",
  cfiRange: "/6/4[...]...",
  audioDataSize: 0, // Check if this is 0
  cacheDir: "/path/to/cache",
  error: {
    name: "Error",
    message: "File was created but is empty (0 bytes)",
    stack: "..."
  }
}
```

**Common Issues:**

- **audioDataSize: 0**: API returned empty data
- **File system errors**: Permission issues or disk full
- **Path errors**: Invalid cache directory

### Step 4: Common Error Patterns

#### Pattern 1: Specific Text Always Fails

**Symptoms:** Same paragraph/text always causes error
**Check:**

1. Text length and content in logs
2. Special characters or encoding issues
3. API response for that specific text

#### Pattern 2: Random Failures

**Symptoms:** Different texts fail at different times
**Check:**

1. Network state in error logs
2. API availability and response times
3. Cache disk space

#### Pattern 3: File Not Playing

**Symptoms:** File exists but won't play
**Check:**

1. File size in cache logs (should be > 0)
2. MediaError code (likely DECODE error)
3. File path validity

#### Pattern 4: All Audio Fails After First Error

**Symptoms:** First error breaks all subsequent audio
**Check:**

1. Audio element state after error
2. Whether cleanup is being called
3. Event listener accumulation (MaxListenersExceeded warning)

## Additional Monitoring

### Success Indicators

Look for these to confirm normal operation:

- `✅ Audio ready to play:` - File loaded successfully
- `✅ Audio playback started successfully` - Playback started
- `>>> Cache: File created successfully` - File written to cache
- `>>> Queue: Emitted audio-ready event` - Queue completed request

### Performance Indicators

- Buffer sizes (should match expected MP3 sizes)
- API response times
- Cache hit/miss ratios
- Queue size and processing status

## Next Steps for Debugging

1. **Click the Info button (ℹ️)** when error occurs to log detailed information
2. **Copy the full error object** from console (look for 📊 marker)
3. **Check the specific paragraph text** that caused the error
4. **Verify the audio file** exists and has non-zero size
5. **Test the audio file** directly by opening the file path shown in logs
6. **Check TTS API health** if generation errors occur
7. **Monitor disk space** for cache operations

## Tips

- Use browser DevTools to filter console logs by emoji markers
- Check Network tab for actual file requests
- Monitor Application tab for file sizes
- Use Performance tab to see event timings
- Save console logs when reproducing errors

## New UI Features

### Error Info Button

When an error occurs, you'll see an **Info button (ℹ️)** next to the error icon in the TTS controls.

**Features:**

- Click to log detailed error information to console
- Shows error count in toast notification
- Provides comprehensive state information:
  - Error messages array
  - Audio element state (src, readyState, networkState, etc.)
  - Current playback state
  - Cache information

**How to use:**

1. When you see the red AlertTriangle icon, click the Info button next to it
2. Check the console for the `📊 Detailed Error Information` log
3. The structured JSON output contains everything you need to debug

## Files Modified

1. `/src/models/Player.ts` - Audio playback error handling + detailed error info method
2. `/src/modules/ttsQueue.ts` - TTS API request logging
3. `/src/modules/ttsService.ts` - Service request tracking
4. `/src/modules/ttsCache.ts` - File system operation logging
5. `/src/components/TTSControls.tsx` - Added error info button to UI
