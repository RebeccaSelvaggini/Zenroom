--[[
--This file is part of zenroom
--
--Copyright (C) 2021 Dyne.org foundation
--designed, written and maintained by Alberto Lerda
--
--This program is free software: you can redistribute it and/or modify
--it under the terms of the GNU Affero General Public License v3.0
--
--This program is distributed in the hope that it will be useful,
--but WITHOUT ANY WARRANTY; without even the implied warranty of
--MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--GNU Affero General Public License for more details.
--
--Along with this program you should have received a copy of the
--GNU Affero General Public License v3.0
--If not, see http://www.gnu.org/licenses/agpl.txt
--
--]]

local btc = {}

function btc.big_from_string(src)
   if not src then
      error("null input to btc.big_from_string", 2)
   end
   local acc = BIG.new(0)
   local ten = BIG.new(10)
   for i=1, #src, 1 do
      local digit = tonumber(src:sub(i,i), 10)
      if digit == nil then
	 error("string is not a BIG number", 2)
      end
      acc = acc * ten + BIG.new(digit)
   end

   return acc
end

local function dSha256(msg)
   local SHA256 = HASH.new('sha256')
   return SHA256:process(SHA256:process(msg))
end

-- MOVE: this function could be implemented in C in the octet class
local function opposite(num)
   local res = O.new()
   for i=#num,1,-1 do
      res = res .. num:sub(i,i)
   end
   return res
end

-- taken from zencode_ecdh
function btc.compress_public_key(public)
   local x, y = ECDH.pubxy(public)
   local pfx = fif( BIG.parity(BIG.new(y) ), OCTET.from_hex('03'), OCTET.from_hex('02') )
   local pk = pfx .. x
   return pk
end

-- it is similar to sign eth, s < order/2
-- MOVE: this function should be in the ECDH module
function btc.sign_ecdh(sk, data) 
   local halfSecp256k1n = INT.new(hex('7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0'))
   local sig
   sig = nil
   repeat
      sig = ECDH.sign_hashed(sk, data, #data)
   until(INT.new(sig.s) < halfSecp256k1n);
   
   return sig
end

function btc.read_base58check(raw)
   raw = O.from_base58(raw)
   local data
   local check
   assert(#raw > 4)
   data = raw:sub(1, #raw-4)
   check = dSha256(data):chop(4)

   assert(raw:sub(#raw-3, #raw) == check)

   return data
end

function btc.read_wif_private_key(sk)
   sk = btc.read_base58check(sk)
   assert(sk:chop(1) == O.from_hex('ef') or sk:chop(1) == O.from_hex('80'))

   -- SEC format used for public key is always compressed
   assert(sk:sub(#sk, #sk) == O.from_hex('01'))

   -- Private key has length 32
   return sk:sub(2, 33)
end

function btc.read_bech32_address(addr)
   local Bech32Chars = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
   local BechInverse = {}
   for i=1,#Bech32Chars,1 do
      BechInverse[Bech32Chars:sub(i,i)] = i-1
   end
   local prefix, data, res, byt, countBit,val
   prefix = nil
   if addr:sub(1,4) == 'bcrt' then
      prefix = 4
   elseif addr:sub(1,2) == 'bc' or addr:sub(1,2) == 'tb' then
      prefix = 2
   end
   if not prefix then
      error("Invalid bech32 prefix", 2)
   end
   -- +3 = do not condider separator and version bit
   data = addr:sub(prefix+3, #addr)

   res = O.new()
   byt=0 -- byte accumulator
   countBit = 0 -- how many bits I have put in the accumulator
   for i=1,#data,1 do
      val = BechInverse[data:sub(i,i)]

      -- Add 5 bits to the buffer
      byt = (byt << 5) + val
      countBit = countBit + 5

      if countBit >= 8 then
	 res = res .. INT.new(byt >> (countBit-8)):octet()

	 byt = byt % (1 << (countBit-8))
  
	 countBit = countBit - 8
      end
   end

   -- TODO: I dont look at the checksum
   
   return res:chop(20)
end

-- variable length encoding for integer based on the
-- actual length of the number
function btc.encode_compact_size(n)
   local res, padding, prefix, le -- littleEndian;

   if type(n) ~= "zenroom.bignum" then
      n = INT.new(n)
   end
   
   padding = 0
   res = O.new()
   if n <= INT.new(252) then
      res = n:octet()
   else
      le = opposite(n:octet())
      prefix = O.new()
      if n <= INT.new('0xffff') then
	 prefix = O.from_hex('fd') 
	 padding = 2
      elseif n <= INT.new('0xffffffff') then
	 prefix = O.from_hex('fe')
	 padding = 4
      elseif n <= INT.new('0xffffffffffffffff') then
	 prefix = O.from_hex('ff')
	 padding = 8
      else
	 padding = #le
      end
      res = prefix .. le
      padding = padding - #le
   end

   if padding > 0 then
      res = res .. O.zero(padding)
   end

   return res
end

-- fixed size encoding for integer
function btc.to_uint(num, nbytes)
   if type(num) ~= "zenroom.bignum" then
      num = INT.new(num)
   end
   num = opposite(num:octet())
   if #num < nbytes then
      num = num .. O.zero(nbytes - #num)
   end
   return num
end

-- with not coinbase input
function btc.build_raw_transaction(tx)
   local raw, script
   raw = O.new()

   if tx["witness"] and #tx["witness"]>0 then
      sigwit = true
   else
      sigwit = false
   end

   -- version
   raw = raw .. O.from_hex('02000000')


   if sigwit then
      -- marker + flags
      raw = raw .. O.from_hex('0001')
   end
   
   raw = raw .. btc.encode_compact_size(INT.new(#tx.txIn))

   -- txIn
   for _, v in pairs(tx.txIn) do
      -- outpoint (hash and index of the transaction)
      raw = raw .. opposite(v.txid) .. btc.to_uint(v.vout, 4)
      -- the script depends on the signature
      script = O.new()

      raw = raw .. btc.encode_compact_size(#script) .. script
      
      -- Sequence number disabled
      raw = raw .. O.from_hex('ffffffff')
   end

   raw = raw .. btc.encode_compact_size(INT.new(#tx.txOut))

   -- txOut
   for _, v in pairs(tx.txOut) do
      --raw = raw .. btc.to_uint(v.amount, 8)
      local amount = O.new(v.amount)
      raw = raw .. opposite(amount)
      if #v.amount < 8 then
	 raw = raw .. O.zero(8 - #amount)
      end
      -- fixed script to send bitcoins
      -- OP_DUP OP_HASH160 20byte
      --script = O.from_hex('76a914')

      --script = script .. v.address

      -- OP_EQUALVERIFY OP_CHECKSIG
      --script = script .. O.from_hex('88ac')
      -- Bech32
      script = O.from_hex('0014')
      script = script .. v.address -- readBech32Address(v.address)
      
      raw = raw .. btc.encode_compact_size(#script) .. script
   end

   if sigwit then
      -- Documentation https://bitcoincore.org/en/segwit_wallet_dev/
      -- The documentation talks about "stack items" but it doesn't specify
      -- which are they, I think that It depends on the type of transaction
      -- (P2SH or P2PKH)

      -- The size of witnesses is not necessary because it is equal to the number of
      -- txin
      --raw = raw .. btc.encode_compact_size(#tx["witness"])

      for _, v in pairs(tx["witness"]) do
	 -- encode all the stack items for the witness
	 raw = raw .. btc.encode_compact_size(#v)
	 for _, s in pairs(v) do
	    raw = raw .. btc.encode_compact_size(#s)
	    raw = raw .. s
	 end
      end
   end

   raw = raw .. O.from_hex('00000000')
   
   return raw
end

local function encode_with_prepend(bytes)
   if tonumber(bytes:sub(1,1):hex(), 16) >= 0x80 then
      bytes = O.from_hex('00') .. bytes
   end

   return bytes
end

function btc.encode_der_signature(sig)
   local res, tmp;

   res = O.new()

   -- r
   tmp = encode_with_prepend(sig.r)
   res = res .. O.from_hex('02') .. INT.new(#tmp):octet() .. tmp

   -- s
   tmp = encode_with_prepend(sig.s)
   res = res .. O.from_hex('02') .. INT.new(#tmp):octet() .. tmp
   
   res = O.from_hex('30') .. INT.new(#res):octet() .. res
   return res
end

local function read_number_from_der(raw, pos)
   local size
   assert(raw:sub(pos, pos) == O.from_hex('02'))
   pos= pos+1
   size = tonumber(raw:sub(pos, pos):hex(), 16)
   pos = pos +1

   -- If the first byte is a 0 do not consider it
   if raw:sub(pos, pos) == O.from_hex('00') then
      pos = pos +1
      size = size -1
   end

   data = raw:sub(pos, pos+size-1)

   return {
      data,
      pos+size
   }
   
   
end

function btc.decode_der_signature(raw)
   local sig, tmp, size;
   sig = {}

   assert(raw:chop(1) == O.from_hex('30'))

   size = tonumber(raw:sub(2,2):hex(), 16)

   tmp = read_number_from_der(raw, 3)

   sig.r = tmp[1]
   tmp = tmp[2]

   tmp = read_number_from_der(raw, tmp)

   sig.s = tmp[1]

   return sig
end

local function hash_prevouts(tx)
   local raw
   local H
   H = HASH.new('sha256')

   raw = O.new()

   for _, v in pairs(tx.txIn) do
      raw = raw .. opposite(v.txid) .. btc.to_uint(v.vout, 4)
   end

   return H:process(H:process(raw))
end

local function hash_sequence(tx)
   local raw
   local H
   local seq
   H = HASH.new('sha256')

   raw = O.new()

   for _, v in pairs(tx.txIn) do
      seq = v['sequence']
      if not seq then
	 -- default value, not enabled
	 seq = O.from_hex('ffffffff')
      end
      raw = raw .. btc.to_uint(seq, 4)
   end
   
   return H:process(H:process(raw))
end

local function hash_outputs(tx)
   local raw
   local H
   local seq
   H = HASH.new('sha256')

   raw = O.new()

   for _, v in pairs(tx.txOut) do
      amount = O.new(v.amount)
      raw = raw .. opposite(amount)
      if #v.amount < 8 then
	 raw = raw .. O.zero(8 - #amount)
      end
      -- This is specific to Bech32 addresses, we should be able to verify the kind of address
      raw = raw .. O.from_hex('160014') .. v.address

   end

   return H:process(H:process(raw))
end


-- BIP0143
-- Double SHA256 of the serialization of:
--      1. nVersion of the transaction (4-byte little endian)
--      2. hash_prevouts (32-byte hash)
--      3. hash_sequence (32-byte hash)
--      4. outpoint (32-byte hash + 4-byte little endian) 
--      5. scriptCode of the input (serialized as scripts inside CTxOuts)
--      6. value of the output spent by this input (8-byte little endian)
--      7. nSequence of the input (4-byte little endian)
--      8. hash_outputs (32-byte hash)
--      9. nLocktime of the transaction (4-byte little endian)
--     10. sighash type of the signature (4-byte little endian)
function btc.build_transaction_to_sign(tx, i)
   local raw
   local amount
   raw = O.new()
   --      1. nVersion of the transaction (4-byte little endian)
   raw = raw .. btc.to_uint(tx.version, 4)
   --      2. hash_prevouts (32-byte hash)
   raw = raw .. hash_prevouts(tx)
   --      3. hash_sequence (32-byte hash)
   raw = raw .. hash_sequence(tx)
   --      4. outpoint (32-byte hash + 4-byte little endian)
   raw = raw .. opposite(tx.txIn[i].txid) .. btc.to_uint(tx.txIn[i].vout, 4)
   --      5. scriptCode of the input (serialized as scripts inside CTxOuts)
   raw = raw .. O.from_hex('1976a914') .. tx.txIn[i].address  .. O.from_hex('88ac')
   --      6. value of the output spent by this input (8-byte little endian)
   amount = O.new(tx.txIn[i].amountSpent)
   raw = raw .. opposite(amount)
   if #amount < 8 then
      raw = raw .. O.zero(8 - #amount)
   end
   --      7. nSequence of the input (4-byte little endian)
   raw = raw .. opposite(tx.txIn[i].sequence)
   --      8. hash_outputs (32-byte hash)
   raw = raw .. hash_outputs(tx)
   --      9. nLocktime of the transaction (4-byte little endian)
   raw = raw .. btc.to_uint(tx.nLockTime, 4)
   --     10. sighash type of the signature (4-byte little endian)
   raw = raw .. btc.to_uint(tx.nHashType, 4)

   return raw
end

-- Here I sign the transaction
function btc.build_witness(tx, sk)
   local pk = btc.compress_public_key(ECDH.pubgen(sk))
   local witness = {}
   for i=1,#tx.txIn,1 do
      if tx.txIn[i].sigwit then
	 local rawTx = btc.build_transaction_to_sign(tx, i)
	 local sigHash = dSha256(rawTx)
	 local sig = btc.sign_ecdh(sk, sigHash)
	 witness[i] = {
	    btc.encode_der_signature(sig) .. O.from_hex('01'),
	    pk
	 }
      else
	 witness[i] = O.zero(1)
      end
   end

   return witness
end
-- -- Pay attention to the amount it has to be multiplied for 10^8

-- unspent: list of unspent transactions
-- sk: private key
-- to: receiver bitcoin address (must be segwit/Bech32!)
-- amount: satoshi to transfer (BIG integer)

-- return nil if it cannot build the transaction
-- (for example if there are not enough founds)
function btc.build_tx_from_unspent(unspent, sk, to, amount, fee)
   local tx, i, currentAmount
   tx = {
      version=2,
      txIn = {},
      txOut = {},
      nLockTime=0,
      nHashType=O.from_hex('00000001')
   }


   i=1
   currentAmount = INT.new(0)
   while i <= #unspent and currentAmount < amount+fee do
      currentAmount = currentAmount + unspent[i].amount
      tx.txIn[i] = {
	 txid = unspent[i].txid,
	 vout = unspent[i].vout,
	 sigwit = true,
	 address = unspent[i].address,
	 amountSpent = unspent[i].amount,
	 sequence = O.from_hex('ffffffff'),
	 --scriptPubKey = unspent[i].scriptPubKey
      }
      i=i+1
   end
   if currentAmount < amount+fee or i==1 then
      -- Not enough BTC
      return nil
   end

   -- Add exactly two outputs, one for the receiver and one for the exceding amount
   tx.txOut[1] = {
      amount = amount,
      address = to
   }

   if currentAmount > amount+fee then
      tx.txOut[2] = {
	 amount = currentAmount-amount-fee,
	 address = tx.txIn[1].address
      }
   end

   return tx
end

function btc.value_btc_to_satoshi(value)
   pos = value:find("%.")
   decimals = value:sub(pos+1, #value)

   if #decimals > 8 then
      error("Satoshi is the smallest unit of measure")
   end

   decimals = decimals .. string.rep("0", 8-#decimals)

   return btc.big_from_string(value:sub(1, pos-1) .. decimals)
end

-- function rawTransactionFromJSON(data, sk)
--    local obj = JSON.decode(data)
--    local sk = btc.read_wif_private_key(sk)

--    for k, v in pairs(obj.unspent) do
--       v.txid = O.from_hex(v.txid)
--       v.amount = valueSatoshiToBTC(v.amount)
--    end

--    local tx = btc.build_tx_from_unspent(obj.unspent, sk, obj.to, btc.big_from_string(obj.amount), btc.big_from_string(obj.fee))

--    tx.witness = btc.build_witness(tx, sk)

--    local rawTx = btc.build_raw_transaction(tx)

--    return rawTx
-- end


return btc