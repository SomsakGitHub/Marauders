// In-memory stand-in for src/auth/appleIdentityToken, swapped in by scripts/test-auth-refresh.mjs so Apple's key server is
// never contacted. The verified subject comes from the token text, so a test picks the account by picking the identity
// token, and a token that starts with "invalid" is one Apple would refuse.

export async function verifyAppleIdentityToken(
  identityToken: string,
  _appleClientId: string,
): Promise<string> {
  if (identityToken.startsWith("invalid")) {
    throw new Error("invalid");
  }
  return `apple:${identityToken}`;
}
