export interface ResolveOptions {
  /** A `process.platform` value. Defaults to this machine's. */
  platform?: string;
  /** A `process.arch` value. Defaults to this machine's. */
  arch?: string;
}

export interface Bundle {
  /** The platform package the bundle was found in. */
  package: string;
  /** AgentCore's own target id, for example `x86_64-windows-msvc`. */
  target: string;
  version: string;
  abiRevision: number;
  /** The bundle directory. `manifest.json` is directly inside it. */
  root: string;
  manifestPath: string;
  includeDir: string;
  libDir: string;
  binDir: string;
  bindingsDir: string;
  sharedLibrary: string;
}

export interface PlatformPackage {
  package: string;
  target: string;
}

/**
 * Where the AgentCore SDK bundle for a platform is installed.
 * Throws when that platform has no bundle or its package is not installed.
 */
export function resolve(options?: ResolveOptions): Bundle;

/** Platform packages by `${process.platform}-${process.arch}`. */
export const packages: Readonly<Record<string, PlatformPackage>>;
