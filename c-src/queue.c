/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "mplex.h"

int q_bound(struct queue* q, int min) {
	if (q->start == q->end) {
		q->start = q->end = 0;
		if (q->size > IDEAL_QUEUE) {
			free(q->data);
			q->data = malloc(IDEAL_QUEUE);
			q->size = IDEAL_QUEUE;
		}
	}
	int slack = q->size - q->end;
	if (slack < min) {
		int size = q->end - q->start;
		if (slack + q->start > min) {
			memmove(q->data, q->data + q->start, size);
			slack += q->start;
			q->start = 0;
			q->end = size;
		} else {
			int newsiz = (size * 3)/2 + min;
			if (newsiz < size + QUEUE_JUMP)
				newsiz = size + QUEUE_JUMP;
			uint8_t* dat = malloc(newsiz);
			memcpy(dat, q->data + q->start, size);
			free(q->data);
			q->data = dat;
			q->size = newsiz;
			q->start = 0;
			q->end = size;
			slack = newsiz - size;
		}
	}
	return slack;
}

int q_read(int fd, struct queue* q) {
	int slack = q_bound(q, MIN_QUEUE);

	int len = read(fd, q->data + q->end, slack);
	if (len > 0) {
		q->end += len;
		return 0;
	} else if (len == -1 && (errno == EAGAIN || errno == EINTR)) {
		return 0;
	} else {
		return (len == 0) ? 1 : 2;
	}
}

int q_write(int fd, struct queue* q) {
	int size = q->end - q->start;
	if (!size)
		return 0;

	int len = write(fd, q->data + q->start, size);
	if (len > 0) {
		q->start += len;
		return 0;
	} else if (len == -1 && (errno == EAGAIN || errno == EINTR)) {
		return 0;
	} else {
		return (len == 0) ? 1 : 2;
	}
}

struct line q_getl(struct queue* q) {
	int i;
	for(i = q->start; i < q->end; i++) {
		if (q->data[i] == '\r' || q->data[i] == '\n') {
			if (i == q->start) {
				q->start++;
			} else {
				struct line rv = {
					.data = q->data + q->start,
					.len = i - q->start,
				};
				q->data[i] = '\0';
				q->start = i+1;
				return rv;
			}
		}
	}
	return (struct line){ NULL, 0 };
}

void q_putl(struct queue* q, struct line line, int newlines) {
	int needed = line.len + newlines;
	q_bound(q, needed);
	memcpy(q->data + q->end, line.data, line.len);
	q->end += line.len;
	if (newlines == 2)
		q->data[q->end++] = '\r';
	if (newlines >= 1)
		q->data[q->end++] = '\n';
}

void qprintf(struct queue* q, const char* format, ...) {
	int slack = q_bound(q, MIN_QUEUE);
	va_list ap;
	va_start(ap, format);
	int n = vsnprintf((char*)q->data + q->end, slack, format, ap);
	va_end(ap);
	while (n >= slack) {
		slack = q_bound(q, n+2);
		va_start(ap, format);
		n = vsnprintf((char*)q->data + q->end, slack, format, ap);
		va_end(ap);
	}
	q->end += n;
}

#define INC(l) do { l.data++; l.len--; } while (0)
#define WRITE(dst, type, value) do { \
	*((type *)(dst)) = (value); \
	dst = (void*)(1 + ((type*)(dst))); \
} while (0)

void sscan(struct line line, const char* format, void* dst) {
	while (1) {
		switch (*format++) {
			case 'i': {
				int v = 0;
				while (line.len && isdigit(*line.data)) {
					v = 10 * v + *line.data - '0';
					INC(line);
				}
				WRITE(dst, int, v);
				break;
			}

			case 's':
				WRITE(dst, uint8_t*, line.data);
			case '-':
				while (line.len && *line.data != ' ')
					INC(line);
				break;

			case 'l':
				WRITE(dst, struct line, line);
				break;

			default:
				return;
		}
		if (line.len && *line.data == ' ') {
			*line.data = '\0';
			INC(line);
		}
	}
}
