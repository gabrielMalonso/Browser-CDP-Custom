export const gatewayVersion = "0.2.1";
export const controlApiVersion = 1;

export const gatewayCapabilities = {
  browserLifecycle: true,
  controlApi: controlApiVersion,
  lazyWorkers: true,
  leases: true,
  profileAliases: true,
} as const;
