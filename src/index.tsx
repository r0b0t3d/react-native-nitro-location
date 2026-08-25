import { NitroModules } from 'react-native-nitro-modules';
import type {
  NitroLocation,
  Location,
  Heading,
  LocationPermissionStatus,
  ConfigureOptions,
  RequestPermissionOptions,
  GetLatestLocationOptions,
  GeofenceRegion,
  GeofenceTransitionEvent,
  StartMonitoringGeofencesResult,
} from './NitroLocation.nitro';

export type {
  Location,
  Heading,
  LocationPermissionStatus,
  ActivityType,
  IosDesiredAccuracy,
  AndroidDesiredAccuracy,
  AndroidProvider,
  IosPermissionType,
  AndroidPermissionDetail,
  DesiredAccuracy,
  ConfigureOptions,
  RequestPermissionOptions,
  GetLatestLocationOptions,
  GeofenceRegion,
  GeofenceTransitionEvent,
  StartMonitoringGeofencesResult,
} from './NitroLocation.nitro';

export type Subscription = () => void;

const hybrid = NitroModules.createHybridObject<NitroLocation>('NitroLocation');

export const configure = (options: ConfigureOptions): Promise<void> =>
  hybrid.configure(options);

export const requestPermission = (
  options: RequestPermissionOptions
): Promise<boolean> => hybrid.requestPermission(options);

export const getCurrentPermission = (): Promise<LocationPermissionStatus> =>
  hybrid.getCurrentPermission();

export const getLatestLocation = (
  options?: GetLatestLocationOptions
): Promise<Location | null> => hybrid.getLatestLocation(options ?? {});

export function subscribeToLocationUpdates(
  listener: (locations: Location[]) => void
): Subscription {
  hybrid.onLocationUpdate = listener;
  hybrid.startLocationUpdates();
  return () => {
    hybrid.onLocationUpdate = null;
    hybrid.stopLocationUpdates();
  };
}

export function subscribeToHeadingUpdates(
  listener: (heading: Heading) => void
): Subscription {
  hybrid.onHeadingUpdate = listener;
  hybrid.startHeadingUpdates();
  return () => {
    hybrid.onHeadingUpdate = null;
    hybrid.stopHeadingUpdates();
  };
}

export function subscribeToPermissionUpdates(
  listener: (status: LocationPermissionStatus) => void
): Subscription {
  hybrid.onPermissionUpdate = listener;
  return () => {
    hybrid.onPermissionUpdate = null;
  };
}

export function subscribeToSignificantLocationUpdates(
  listener: (locations: Location[]) => void
): Subscription {
  hybrid.onSignificantLocationUpdate = listener;
  hybrid.startSignificantLocationUpdates();
  return () => {
    hybrid.onSignificantLocationUpdate = null;
    hybrid.stopSignificantLocationUpdates();
  };
}

export function subscribeToGeofenceTransitions(
  listener: (event: GeofenceTransitionEvent) => void
): Subscription {
  hybrid.onGeofenceTransition = listener;
  return () => {
    hybrid.onGeofenceTransition = null;
  };
}

export const startMonitoringGeofences = (
  regions: GeofenceRegion[]
): Promise<StartMonitoringGeofencesResult> =>
  hybrid.startMonitoringGeofences(regions);

export const stopMonitoringGeofences = (): void =>
  hybrid.stopMonitoringGeofences();

export const getPendingGeofenceTransition =
  (): GeofenceTransitionEvent | null => hybrid.getPendingGeofenceTransition();
