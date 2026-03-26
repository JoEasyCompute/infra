function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

export function validateSyncRequest(payload) {
  const errors = [];

  if (!payload || typeof payload !== "object") {
    return ["body must be an object"];
  }

  if (!isNonEmptyString(payload.site_code)) {
    errors.push("site_code is required");
  }

  if (!payload.machine || typeof payload.machine !== "object") {
    errors.push("machine is required");
    return errors;
  }

  if (!isNonEmptyString(payload.machine.hostname)) {
    errors.push("machine.hostname is required");
  }

  if (!isNonEmptyString(payload.machine.maas_system_id)) {
    errors.push("machine.maas_system_id is required");
  }

  if (!isNonEmptyString(payload.machine.cpu_model)) {
    errors.push("machine.cpu_model is required");
  }

  if (!Number.isInteger(payload.machine.cpu_cores_total) || payload.machine.cpu_cores_total <= 0) {
    errors.push("machine.cpu_cores_total must be a positive integer");
  }

  if (!Number.isInteger(payload.machine.ram_gb) || payload.machine.ram_gb <= 0) {
    errors.push("machine.ram_gb must be a positive integer");
  }

  if (!Array.isArray(payload.machine.gpus)) {
    errors.push("machine.gpus must be an array");
  }

  return errors;
}
