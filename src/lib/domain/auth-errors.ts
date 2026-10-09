type AuthFailure = { code?: string; status?: number; message?: string };

// Never return provider messages verbatim: they may include implementation details.
export function loginFailure(error: AuthFailure) {
  if (/invalid api key/i.test(error.message ?? '') || error.code === 'invalid_api_key') {
    return { reference: 'AUTH_CONFIG', message: 'The site connection to Supabase was rejected. Reference: AUTH_CONFIG.' };
  }
  const messages: Record<string, string> = {
    invalid_credentials: 'Supabase rejected the email or password for this site. Reference: AUTH_CREDENTIALS.',
    email_not_confirmed: 'This account email still needs to be confirmed. Reference: AUTH_EMAIL.',
    user_banned: 'Access for this account is suspended. Reference: AUTH_BLOCKED.',
    email_provider_disabled: 'Email sign-in is disabled for the connected project. Reference: AUTH_PROVIDER.',
    signup_disabled: 'This operation is not enabled for the connected project. Reference: AUTH_PROVIDER.',
  };
  if (error.code && messages[error.code]) {
    return { reference: error.code, message: messages[error.code] };
  }
  if (error.status === 429) return { reference: 'AUTH_RATE_LIMIT', message: 'Too many attempts. Wait a few minutes before trying again. Reference: AUTH_RATE_LIMIT.' };
  return { reference: 'AUTH_UNAVAILABLE', message: 'The Supabase connection could not be completed. Reference: AUTH_UNAVAILABLE.' };
}
