/* This file is part of Zenroom (https://zenroom.dyne.org)
 *
 * Copyright (C) 2022 Dyne.org foundation
 * designed, written and maintained by Denis Roio <jaromil@dyne.org>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 */

// external API function for streaming hash

#include <stdlib.h>
#include <strings.h> // libc

#include <amcl.h>
#include <ecdh_support.h> // AMCL

#include <zen_error.h>
#include <encoding.h> // zenroom

 // first byte is type
#define SHA512 64

// returns a fills hash_ctx, which must be pre-allocated externally
int zenroom_hash_init(const char *hash_type,
		      char *hash_ctx, const int hash_ctx_size) {
  register char prefix = '0';
  // size tests
  register int len = 0; 
  void *sh;
  if(strcasecmp(hash_type, "sha512") == 0) {    
    prefix = '4';
    len = sizeof(hash512); // amcl struct
    sh = malloc(len);
    // TODO: check what malloc returns
    HASH512_init((hash512*)sh); // amcl init
  } else {
    zerror(NULL, "%s :: invalid hash type: %s", __func__, hash_type);
    return 4; // ERR_INIT
  }
  if(hash_ctx_size < (len+4)<<1) { // size*2 because hex encoded
    free(sh);
    zerror(NULL, "%s :: invalid hash context size: %u <= %u",
	   __func__, hash_ctx_size, (len+4)<<1);
    return 4;
  }

  // serialize
  hash_ctx[0] = prefix;
  buf2hex(hash_ctx+1, (const char*)sh, (const size_t)len);
  hash_ctx[(len<<1)+2] = 0x0; // null terminated string
  free(sh);
  return 0;
}

// returns hash_ctx updated
int zenroom_hash_update(char *hash_ctx,
			const char *buffer, const int buffer_size) {
  register char prefix = hash_ctx[0];
  register int len;
  char *sh;
  if(prefix=='4') {
    len = sizeof(hash512);
    sh = (char*)malloc(len);
    hex2buf(sh, hash_ctx+1);
    register int c;
    for(c=0; c<buffer_size; c++) {
      HASH512_process((hash512*)sh, buffer[c]);
    }
    buf2hex(hash_ctx+1, (const char*)sh, (const size_t)len);
  } else {
    zerror(NULL, "%s :: invalid hash context prefix: %c", __func__, prefix);
    return 3;
  }
  free(sh);
  return 0;
}

// returns the hash string base64 encoded
int zenroom_hash_final(const char *hash_ctx,
		       char *hash_result, const int hash_result_size) {
  register int len;
  register char prefix = hash_ctx[0];
  octet tmp;
  char *sh;
  if(prefix=='4') { // sha512
    if(hash_result_size<90) { // base64 is 88 with padding
      zerror(NULL, "%s :: invalid hash result size: %u <= %u",
	     __func__, hash_result_size, 64);
      return 3;
    }
    tmp.len = 64;
    tmp.val = (char*)malloc(64);
    len = sizeof(hash512);
    sh = (char*)malloc(len);
    hex2buf(sh, hash_ctx+1);
    HASH512_hash((hash512*)sh, tmp.val);
  } else {
    zerror(NULL, "%s :: invalid hash context prefix: %c", __func__, prefix);
    return 3;
  }
  OCT_tobase64(hash_result,&tmp);
  free(tmp.val);
  return 0;
}
