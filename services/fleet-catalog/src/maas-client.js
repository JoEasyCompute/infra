import { getConfig } from "./config.js";

function percentEncode(value) {
  return encodeURIComponent(value).replace(/[!'()*]/g, (char) => `%${char.charCodeAt(0).toString(16).toUpperCase()}`);
}

export function buildMaasAuthorizationHeader(apiKey) {
  const [consumerKey, tokenKey, tokenSecret] = `${apiKey || ""}`.split(":");
  if (!consumerKey || !tokenKey || !tokenSecret) {
    throw new Error("MAAS_API_KEY must be in consumer:token:secret format");
  }

  return [
    "OAuth",
    `oauth_version="${percentEncode("1.0")}"`,
    `oauth_signature_method="${percentEncode("PLAINTEXT")}"`,
    `oauth_consumer_key="${percentEncode(consumerKey)}"`,
    `oauth_token="${percentEncode(tokenKey)}"`,
    `oauth_signature="${percentEncode(`&${tokenSecret}`)}"`
  ].join(" ");
}

export function createMaasClient(options = {}) {
  const config = getConfig();
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const baseUrl = options.baseUrl || config.maasBaseUrl;
  const apiKey = options.apiKey || config.maasApiKey;
  const apiVersion = options.apiVersion || config.maasApiVersion;

  if (!fetchImpl) {
    throw new Error("fetch implementation is not available");
  }

  if (!baseUrl) {
    throw new Error("MAAS_BASE_URL is required");
  }

  if (!apiKey) {
    throw new Error("MAAS_API_KEY is required");
  }

  const normalizedBaseUrl = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const authHeader = buildMaasAuthorizationHeader(apiKey);

  async function request(pathname) {
    const url = new URL(`api/${apiVersion}/${pathname}`, normalizedBaseUrl);
    const response = await fetchImpl(url, {
      method: "GET",
      headers: {
        Accept: "application/json",
        Authorization: authHeader
      }
    });

    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`MAAS request failed (${response.status} ${response.statusText}): ${detail}`);
    }

    return response.json();
  }

  return {
    async listMachines() {
      return request("machines/");
    },

    async getMachine(systemId) {
      return request(`machines/${encodeURIComponent(systemId)}/`);
    }
  };
}
