#ifndef CBASE_B64_H
#define CBASE_B64_H
#include <stddef.h>
/* Standard base64 (RFC 4648, '+' '/', '=' padding). */
size_t b64_encoded_len(size_t n);
/* Writes b64_encoded_len(n) bytes (no terminator). */
void b64_encode(const unsigned char *in, size_t n, char *out);
/* Upper bound on decoded size. */
size_t b64_decoded_max(size_t n);
/* Returns the decoded length, or -1 if `in` is not canonical padded base64. */
long b64_decode(const char *in, size_t n, unsigned char *out);
#endif
