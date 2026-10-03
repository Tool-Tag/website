type AuthFailure = { code?: string; status?: number; message?: string };

// Never return provider messages verbatim: they may include implementation details.
export function loginFailure(error: AuthFailure) {
  if (/invalid api key/i.test(error.message ?? '') || error.code === 'invalid_api_key') {
    return { reference: 'AUTH_CONFIG', message: 'La conexión del sitio con Supabase fue rechazada. Referencia: AUTH_CONFIG.' };
  }
  const messages: Record<string, string> = {
    invalid_credentials: 'Supabase rechazó el correo o la contraseña en este sitio. Referencia: AUTH_CREDENTIALS.',
    email_not_confirmed: 'Falta confirmar el correo de esta cuenta. Referencia: AUTH_EMAIL.',
    user_banned: 'El acceso de esta cuenta está suspendido. Referencia: AUTH_BLOCKED.',
    email_provider_disabled: 'El acceso por correo está desactivado en el proyecto conectado. Referencia: AUTH_PROVIDER.',
    signup_disabled: 'Esta operación no está habilitada en el proyecto conectado. Referencia: AUTH_PROVIDER.',
  };
  if (error.code && messages[error.code]) {
    return { reference: error.code, message: messages[error.code] };
  }
  if (error.status === 429) return { reference: 'AUTH_RATE_LIMIT', message: 'Hay demasiados intentos. Espera unos minutos antes de volver a entrar. Referencia: AUTH_RATE_LIMIT.' };
  return { reference: 'AUTH_UNAVAILABLE', message: 'No se pudo completar la conexión con Supabase. Referencia: AUTH_UNAVAILABLE.' };
}
