# react-native-nitro-location

High-performance location library for React Native, built on [Nitro Modules](https://nitro.margelo.com/).

## Installation

```sh
npm install react-native-nitro-location react-native-nitro-modules
```

### iOS

```sh
cd ios && pod install
```

Add to `Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs location access.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>This app needs background location access.</string>
```

### Android

Add to `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<!-- Optional: background location -->
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
```

## Usage

### Request permission

```ts
import { requestPermission, getCurrentPermission } from 'react-native-nitro-location';

const granted = await requestPermission({
  ios: 'whenInUse',
  android: 'fine',
});

const status = await getCurrentPermission();
// 'authorizedFine' | 'authorizedCoarse' | 'authorizedWhenInUse' | 'authorizedAlways' | 'denied' | 'restricted' | 'notDetermined'
```

### Subscribe to location updates

```ts
import { subscribeToLocationUpdates } from 'react-native-nitro-location';

const unsubscribe = subscribeToLocationUpdates((locations) => {
  const latest = locations[locations.length - 1];
  console.log(latest.latitude, latest.longitude);
});

// Stop updates
unsubscribe();
```

### Subscribe to heading updates

```ts
import { subscribeToHeadingUpdates } from 'react-native-nitro-location';

const unsubscribe = subscribeToHeadingUpdates((heading) => {
  console.log('Heading:', heading.heading);
});

unsubscribe();
```

### Subscribe to permission changes

```ts
import { subscribeToPermissionUpdates } from 'react-native-nitro-location';

const unsubscribe = subscribeToPermissionUpdates((status) => {
  console.log('Permission changed:', status);
});

unsubscribe();
```

### Significant location updates (iOS / coarse Android)

```ts
import { subscribeToSignificantLocationUpdates } from 'react-native-nitro-location';

const unsubscribe = subscribeToSignificantLocationUpdates((locations) => {
  console.log('Significant change:', locations[0]);
});

unsubscribe();
```

### One-shot location

```ts
import { getLatestLocation } from 'react-native-nitro-location';

const location = await getLatestLocation({ maximumAge: 5000, timeout: 10000 });
if (location) {
  console.log(location.latitude, location.longitude);
}
```

### Configure

```ts
import { configure } from 'react-native-nitro-location';

await configure({
  distanceFilter: 10,                  // metres between updates
  desiredAccuracy: {
    ios: 'best',
    android: 'highAccuracy',
  },
  allowsBackgroundLocationUpdates: true,  // iOS
  activityType: 'fitness',               // iOS
  interval: 2000,                        // Android, ms
  fastestInterval: 1000,                 // Android, ms
  androidProvider: 'auto',              // 'auto' | 'playServices' | 'standard'
});
```

## API

### Methods

| Method | Description |
|---|---|
| `configure(options)` | Set accuracy, distance filter, activity type, update interval |
| `requestPermission(options)` | Request location permission. Resolves `true` if granted |
| `getCurrentPermission()` | Get current permission status |
| `getLatestLocation(options?)` | One-shot location fetch with optional age/timeout |
| `subscribeToLocationUpdates(listener)` | Continuous GPS updates. Returns unsubscribe function |
| `subscribeToHeadingUpdates(listener)` | Compass heading updates. Returns unsubscribe function |
| `subscribeToPermissionUpdates(listener)` | Permission change events. Returns unsubscribe function |
| `subscribeToSignificantLocationUpdates(listener)` | Low-power significant-change updates. Returns unsubscribe function |

### Types

```ts
interface Location {
  timestamp: number;          // ms since epoch
  latitude: number;
  longitude: number;
  accuracy: number;           // metres
  altitude: number;           // metres
  altitudeAccuracy: number;
  course: number;             // degrees
  courseAccuracy?: number;    // Android
  speed: number;              // m/s
  speedAccuracy?: number;     // Android
  floor?: number;             // iOS
  fromMockProvider?: boolean; // Android
}

interface Heading {
  heading: number;            // degrees (0–360)
}

type LocationPermissionStatus =
  | 'authorizedAlways'        // iOS
  | 'authorizedWhenInUse'     // iOS
  | 'authorizedFine'          // Android
  | 'authorizedCoarse'        // Android
  | 'denied'
  | 'restricted'
  | 'notDetermined';
```

## License

MIT
