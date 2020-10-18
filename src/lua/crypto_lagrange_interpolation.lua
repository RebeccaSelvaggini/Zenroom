-- This file is part of Zenroom (https://zenroom.dyne.org)
--
-- Copyright (C) 2020 Dyne.org foundation
-- Implementation by Alberto Ibrisevich and Denis Roio
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.


local li = {
   _VERSION = 'crypto_lagrange_interpolation.lua 1.0',
   _URL = 'https://zenroom.dyne.org',
   _DESCRIPTION = 'Secret Sharing based on BIG INT using Lagrange Interpolation over 1st order elliptic curves",Attribute-based credential system supporting multiple unlinkable private attribute revelations',
   _LICENSE = [[
Licensed under the terms of the GNU Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.  Unless required by applicable
law or agreed to in writing, software distributed under the License
is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.
]]
}

local G1 = ECP.generator() -- return value
local O  = ECP.order() -- return value

function li.create_shared_secret(total, quorum)
   assert(quorum < total, 'Error calling create_shared_secret: quorum ('..quorum..') must be smaller than total ('..total..')')
   -- generation of the coefficients of the secret polynomial
   local coeff = { }
   for i=1,quorum,1 do
	  coeff[i] = BIG.random()
   end
   --generation of the shares
   local shares = { }
   for i=1,total,1 do
	  local x = BIG.random()
	  --provides trivial unleakability: x coordinate is never zero
	  while (x == 0) do
		 x = BIG.random()
		 if x ~=0 then
			--checking for duplicates in shares
			for k in pairs(shares) do
			   if x == k then x = 0 end
			end
		 end
	  end
	  local y = coeff[1]     --a_0
	  local x_n = BIG.new(1)
	  for n=2,quorum,1 do
		 x_n = x_n:modmul(x) -- x^(n-1)
		 y = BIG.add(y, coeff[n]:modmul(x_n))
		 y = BIG.mod(y, O) -- +a_(n-1)x^(n-1)
	  end
	  table.insert(shares, {x = x, y = y})
   end -- for i,total
   -- overwrite secret for secure disposal
   return shares, coeff[1]
end

function li.compose_shared_secret(shares)
   local sec = BIG.new(0)
   local num
   local den
   local quorum = #shares
   for i = 1,quorum,1 do
	  if quorum % 2 == 1 then
		 num = BIG.new(1)
	  else
		 num = BIG.new(BIG.modneg(1))
	  end
	  den = BIG.new(1)
	  for j = 1,quorum,1 do
		 if j~=i then
			num = num:modmul(shares[j].x)
			den = den:modmul((shares[i].x):modsub(shares[j].x, O))
		 end
	  end
	  sec = BIG.add(sec, (shares[i].y):modmul(num:moddiv(den, O)))
	  sec = BIG.mod(sec, O)
   end
   return sec
end

return li