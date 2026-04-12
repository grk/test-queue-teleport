const KEY_ID_LENGTH = 6;
const SECRET_LENGTH = 32; // 32 bytes = 64 hex chars

function generateKeyId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(KEY_ID_LENGTH / 2 + 1));
  return Array.from(bytes)
    .map((b) => b.toString(36))
    .join("")
    .slice(0, KEY_ID_LENGTH);
}

function generateSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(SECRET_LENGTH));
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function hashSecret(secret: string): Promise<string> {
  const encoded = new TextEncoder().encode(secret);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function main() {
  const teamName = process.argv[2] || "default";

  const keyId = generateKeyId();
  const secret = generateSecret();
  const secretHash = await hashSecret(secret);
  const fullKey = `tqt_${keyId}_${secret}`;

  // Generate a separate encryption key
  const encryptionKey = generateSecret();

  console.log("=== New API Key ===");
  console.log("");
  console.log(`Full key (save as GHA secret TQ_TELEPORT_API_KEY):`);
  console.log(`  ${fullKey}`);
  console.log("");
  console.log(`Insert into D1:`);
  console.log(
    `  bun wrangler d1 execute tq-teleport-db --command "INSERT INTO api_keys (id, secret_hash, team_name) VALUES ('${keyId}', '${secretHash}', '${teamName}')"`
  );
  console.log("");
  console.log(`For remote (deployed) database, add --remote flag.`);
  console.log("");
  console.log("=== Encryption Key (optional, for E2E encryption) ===");
  console.log("");
  console.log(`Encryption key (save as GHA secret TQ_TELEPORT_ENCRYPTION_KEY):`);
  console.log(`  ${encryptionKey}`);
  console.log("");
  console.log(`The encryption key never leaves your CI runners.`);
  console.log(`The relay cannot read test data when this is set.`);
}

main();
