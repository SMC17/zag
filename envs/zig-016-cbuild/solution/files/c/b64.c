#include "b64.h"
static const char A[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
size_t b64_encoded_len(size_t n) { return ((n + 2) / 3) * 4; }
size_t b64_decoded_max(size_t n) { return (n / 4) * 3; }
void b64_encode(const unsigned char *in, size_t n, char *out) {
    size_t i = 0, o = 0;
    for (; i + 2 < n; i += 3) {
        unsigned v = (in[i] << 16) | (in[i + 1] << 8) | in[i + 2];
        out[o++] = A[(v >> 18) & 63]; out[o++] = A[(v >> 12) & 63];
        out[o++] = A[(v >> 6) & 63];  out[o++] = A[v & 63];
    }
    if (n - i == 1) {
        unsigned v = in[i] << 16;
        out[o++] = A[(v >> 18) & 63]; out[o++] = A[(v >> 12) & 63]; out[o++] = '='; out[o++] = '=';
    } else if (n - i == 2) {
        unsigned v = (in[i] << 16) | (in[i + 1] << 8);
        out[o++] = A[(v >> 18) & 63]; out[o++] = A[(v >> 12) & 63]; out[o++] = A[(v >> 6) & 63]; out[o++] = '=';
    }
}
static int val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}
long b64_decode(const char *in, size_t n, unsigned char *out) {
    if (n % 4 != 0) return -1;
    size_t o = 0;
    for (size_t i = 0; i < n; i += 4) {
        int last = (i + 4 == n);
        int a = val(in[i]), b = val(in[i + 1]);
        if (a < 0 || b < 0) return -1;
        if (last && in[i + 2] == '=' && in[i + 3] == '=') {
            if (b & 15) return -1; /* non-canonical */
            out[o++] = (unsigned char)((a << 2) | (b >> 4));
            break;
        }
        int c = val(in[i + 2]);
        if (c < 0) return -1;
        if (last && in[i + 3] == '=') {
            if (c & 3) return -1;
            out[o++] = (unsigned char)((a << 2) | (b >> 4));
            out[o++] = (unsigned char)(((b & 15) << 4) | (c >> 2));
            break;
        }
        int d = val(in[i + 3]);
        if (d < 0) return -1;
        out[o++] = (unsigned char)((a << 2) | (b >> 4));
        out[o++] = (unsigned char)(((b & 15) << 4) | (c >> 2));
        out[o++] = (unsigned char)(((c & 3) << 6) | d);
    }
    return (long)o;
}
