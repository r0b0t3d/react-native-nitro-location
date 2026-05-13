import { NitroModules } from 'react-native-nitro-modules';
import type { NitroLocation } from './NitroLocation.nitro';

const NitroLocationHybridObject =
  NitroModules.createHybridObject<NitroLocation>('NitroLocation');

export function multiply(a: number, b: number): number {
  return NitroLocationHybridObject.multiply(a, b);
}
