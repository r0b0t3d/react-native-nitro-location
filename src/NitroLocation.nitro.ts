import type { HybridObject } from 'react-native-nitro-modules';

export interface Location {
  timestamp: number;
  latitude: number;
  longitude: number;
  accuracy: number;
  altitude: number;
  altitudeAccuracy: number;
  course: number;
  courseAccuracy?: number;
  speed: number;
  speedAccuracy?: number;
  floor?: number;
  fromMockProvider?: boolean;
}

export interface Heading {
  heading: number;
}

export type LocationPermissionStatus =
  | 'authorizedAlways'
  | 'authorizedWhenInUse'
  | 'authorizedFine'
  | 'authorizedCoarse'
  | 'denied'
  | 'restricted'
  | 'notDetermined';

export type ActivityType =
  | 'other'
  | 'automotiveNavigation'
  | 'fitness'
  | 'otherNavigation'
  | 'airborne';

export type IosDesiredAccuracy =
  | 'bestForNavigation'
  | 'best'
  | 'nearestTenMeters'
  | 'hundredMeters'
  | 'threeKilometers';

export type AndroidDesiredAccuracy =
  | 'highAccuracy'
  | 'balancedPowerAccuracy'
  | 'lowPower'
  | 'noPower';

export type AndroidProvider = 'auto' | 'playServices' | 'standard';

export type IosPermissionType = 'always' | 'whenInUse';

export type AndroidPermissionDetail = 'fine' | 'coarse';

export interface DesiredAccuracy {
  ios?: IosDesiredAccuracy;
  android?: AndroidDesiredAccuracy;
}

export interface ConfigureOptions {
  distanceFilter?: number;
  activityType?: ActivityType;
  allowsBackgroundLocationUpdates?: boolean;
  showsBackgroundLocationIndicator?: boolean;
  desiredAccuracy?: DesiredAccuracy;
  androidProvider?: AndroidProvider;
  interval?: number;
  fastestInterval?: number;
}

export interface RequestPermissionOptions {
  ios?: IosPermissionType;
  android?: AndroidPermissionDetail;
}

export interface GetLatestLocationOptions {
  timeout?: number;
  maximumAge?: number;
}

export interface StartMonitoringGeofencesResult {
  monitoredCount: number;
}

export interface GeofenceRegion {
  identifier: string;
  latitude: number;
  longitude: number;
  radiusMeters: number;
}

export type GeofenceTransitionType = 'enter' | 'exit';

export interface GeofenceTransitionEvent {
  identifier: string;
  type: GeofenceTransitionType;
}

export interface NitroLocation extends HybridObject<{
  ios: 'swift';
  android: 'kotlin';
}> {
  // Config
  configure(options: ConfigureOptions): Promise<void>;

  // Permissions
  requestPermission(options: RequestPermissionOptions): Promise<boolean>;
  getCurrentPermission(): Promise<LocationPermissionStatus>;

  // One-shot
  getLatestLocation(
    options: GetLatestLocationOptions
  ): Promise<Location | null>;

  // Streaming callbacks
  onLocationUpdate: ((locations: Location[]) => void) | null;
  onHeadingUpdate: ((heading: Heading) => void) | null;
  onPermissionUpdate: ((status: LocationPermissionStatus) => void) | null;
  onSignificantLocationUpdate: ((locations: Location[]) => void) | null;

  // Stream control
  startLocationUpdates(): void;
  stopLocationUpdates(): void;
  startHeadingUpdates(): void;
  stopHeadingUpdates(): void;
  startSignificantLocationUpdates(): void;
  stopSignificantLocationUpdates(): void;

  // Geofencing
  onGeofenceTransition: ((event: GeofenceTransitionEvent) => void) | null;
  startMonitoringGeofences(
    regions: GeofenceRegion[]
  ): Promise<StartMonitoringGeofencesResult>;
  stopMonitoringGeofences(): void;
  getPendingGeofenceTransition(): GeofenceTransitionEvent | null;
}
