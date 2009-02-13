/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "mplex.h"

int q_bound(struct queue* q, int min, int max) {
	if (q->start == q->end) {
		q->start = q->end = 0;
		if (max && q->size > max) {
			free(q->data);
			q->data = malloc(max);
			q->size = max;
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
	int slack = q_bound(q, MIN_QUEUE, IDEAL_QUEUE);

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

char* q_gets(struct queue* q) {
	int i;
	for(i = q->start; i < q->end; i++) {
		if (q->data[i] == '\r' || q->data[i] == '\n') {
			if (i == q->start) {
				q->start++;
			} else {
				uint8_t* rv = q->data + q->start;
				q->data[i] = '\0';
				q->start = i+1;
				return (char*)rv;
			}
		}
	}
	return NULL;
}

void q_puts(struct queue* q, const char* line, int newlines) {
	int slen = strlen(line);
	int needed = slen + newlines;
	q_bound(q, needed, IDEAL_QUEUE);
	memcpy(q->data + q->end, line, slen);
	q->end += slen;
	if (newlines == 2)
		q->data[q->end++] = '\r';
	if (newlines >= 1)
		q->data[q->end++] = '\n';
}

void qprintf(struct queue* q, const char* format, ...) {
	int slack = q_bound(q, MIN_QUEUE, IDEAL_QUEUE);
	va_list ap;
	va_start(ap, format);
	int n = vsnprintf((char*)q->data + q->end, slack, format, ap);
	va_end(ap);
	while (n >= slack) {
		slack = q_bound(q, n+2, IDEAL_QUEUE);
		va_start(ap, format);
		n = vsnprintf((char*)q->data + q->end, slack, format, ap);
		va_end(ap);
	}
	q->end += n;
}
