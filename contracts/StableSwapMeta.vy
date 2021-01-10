# @version ^0.2.8
"""
@title StableSwap
@author Curve.Fi
@license Copyright (c) Curve.Fi, 2020 - all rights reserved
@notice Metapool implementation
"""

#from vyper.interfaces import ERC20


interface ERC20:
    def transfer(_receiver: address, _amount: uint256): nonpayable
    def transferFrom(_sender: address, _receiver: address, _amount: uint256): nonpayable
    def approve(_spender: address, _amount: uint256): nonpayable
    def decimals() -> uint256: view
    def balanceOf(_owner: address) -> uint256: view


interface CurveToken:
    def totalSupply() -> uint256: view
    def mint(_to: address, _value: uint256) -> bool: nonpayable
    def burnFrom(_to: address, _value: uint256) -> bool: nonpayable

interface Curve:
    def coins(i: uint256) -> address: view
    def get_virtual_price() -> uint256: view
    def calc_token_amount(amounts: uint256[BASE_N_COINS], deposit: bool) -> uint256: view
    def calc_withdraw_one_coin(_token_amount: uint256, i: int128) -> uint256: view
    def fee() -> uint256: view
    def get_dy(i: int128, j: int128, dx: uint256) -> uint256: view
    def get_dy_underlying(i: int128, j: int128, dx: uint256) -> uint256: view
    def exchange(i: int128, j: int128, dx: uint256, min_dy: uint256): nonpayable
    def add_liquidity(amounts: uint256[BASE_N_COINS], min_mint_amount: uint256): nonpayable
    def remove_liquidity_one_coin(_token_amount: uint256, i: int128, min_amount: uint256): nonpayable


# Events
event Transfer:
    _from: indexed(address)
    _to: indexed(address)
    _value: uint256

event Approval:
    _owner: indexed(address)
    _spender: indexed(address)
    _value: uint256

event TokenExchange:
    buyer: indexed(address)
    sold_id: int128
    tokens_sold: uint256
    bought_id: int128
    tokens_bought: uint256

event TokenExchangeUnderlying:
    buyer: indexed(address)
    sold_id: int128
    tokens_sold: uint256
    bought_id: int128
    tokens_bought: uint256

event AddLiquidity:
    provider: indexed(address)
    token_amounts: uint256[N_COINS]
    fees: uint256[N_COINS]
    invariant: uint256
    token_supply: uint256

event RemoveLiquidity:
    provider: indexed(address)
    token_amounts: uint256[N_COINS]
    fees: uint256[N_COINS]
    token_supply: uint256

event RemoveLiquidityOne:
    provider: indexed(address)
    token_amount: uint256
    coin_amount: uint256
    token_supply: uint256

event RemoveLiquidityImbalance:
    provider: indexed(address)
    token_amounts: uint256[N_COINS]
    fees: uint256[N_COINS]
    invariant: uint256
    token_supply: uint256

event CommitNewAdmin:
    deadline: indexed(uint256)
    admin: indexed(address)

event NewAdmin:
    admin: indexed(address)

event CommitNewFee:
    deadline: indexed(uint256)
    fee: uint256
    admin_fee: uint256

event NewFee:
    fee: uint256
    admin_fee: uint256

event RampA:
    old_A: uint256
    new_A: uint256
    initial_time: uint256
    future_time: uint256

event StopRampA:
    A: uint256
    t: uint256


N_COINS: constant(int128) = 2
MAX_COIN: constant(int128) = N_COINS - 1

FEE_DENOMINATOR: constant(uint256) = 10 ** 10
PRECISION: constant(uint256) = 10 ** 18  # The precision to convert to
BASE_N_COINS: constant(int128) = 3

MAX_ADMIN_FEE: constant(uint256) = 10 * 10 ** 9
MAX_FEE: constant(uint256) = 5 * 10 ** 9
MAX_A: constant(uint256) = 10 ** 6
MAX_A_CHANGE: constant(uint256) = 10

ADMIN_ACTIONS_DELAY: constant(uint256) = 3 * 86400
MIN_RAMP_TIME: constant(uint256) = 86400

coins: public(address[N_COINS])
balances: public(uint256[N_COINS])
fee: public(uint256)  # fee * 1e10

ADMIN_FEE: constant(uint256) = 5000000000

owner: public(address)

# Token corresponding to the pool is always the last one
BASE_CACHE_EXPIRES: constant(int128) = 10 * 60  # 10 min
base_virtual_price: public(uint256)
base_cache_updated: public(uint256)

A_PRECISION: constant(uint256) = 100
initial_A: public(uint256)
future_A: public(uint256)
initial_A_time: public(uint256)
future_A_time: public(uint256)

rate: uint256

FEE_RECEIVER: constant(address) = 0xA464e6DCda8AC41e03616F95f4BC98a13b8922Dc
BASE_POOL: constant(address) = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7
BASE_COINS: constant(address[3]) = [
    0x6B175474E89094C44Da98b954EedeAC495271d0F,
    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
    0xdAC17F958D2ee523a2206206994597C13D831ec7
]

name: public(String[64])
symbol: public(String[32])

balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])
totalSupply: public(uint256)


@external
def initialize(_coin: address, _A: uint256, _fee: uint256):
    """
    @notice Contract constructor
    @param _coin Addresses of ERC20 conracts of coins
    @param _A Amplification coefficient multiplied by n * (n - 1)
    @param _fee Fee to charge for exchanges
    """
    assert _fee >= 4000000
    assert self.fee == 0

    self.coins = [_coin, 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490]
    self.initial_A = _A * A_PRECISION
    self.future_A = _A * A_PRECISION
    self.fee = _fee

    decimals: uint256 = ERC20(_coin).decimals()
    self.rate = 10 ** (18-decimals)

    base_pool: address = BASE_POOL
    self.base_virtual_price = Curve(base_pool).get_virtual_price()
    self.base_cache_updated = block.timestamp
    base_coins: address[3] = BASE_COINS
    for i in range(BASE_N_COINS):
        ERC20(base_coins[i]).approve(base_pool, MAX_UINT256)


@view
@internal
def _A() -> uint256:
    """
    Handle ramping A up or down
    """
    t1: uint256 = self.future_A_time
    A1: uint256 = self.future_A

    if block.timestamp < t1:
        A0: uint256 = self.initial_A
        t0: uint256 = self.initial_A_time
        # Expressions in uint256 cannot have negative numbers, thus "if"
        if A1 > A0:
            return A0 + (A1 - A0) * (block.timestamp - t0) / (t1 - t0)
        else:
            return A0 - (A0 - A1) * (block.timestamp - t0) / (t1 - t0)

    else:  # when t1 == 0 or block.timestamp >= t1
        return A1


@view
@external
def A() -> uint256:
    return self._A() / A_PRECISION


@view
@external
def A_precise() -> uint256:
    return self._A()


@view
@internal
def _xp(vp_rate: uint256) -> uint256[N_COINS]:
    result: uint256[N_COINS] = [self.rate, vp_rate]
    for i in range(N_COINS):
        result[i] = result[i] * self.balances[i] / PRECISION
    return result


@pure
@internal
def _xp_mem(_rates: uint256[N_COINS], _balances: uint256[N_COINS]) -> uint256[N_COINS]:
    result: uint256[N_COINS] = _rates
    for i in range(N_COINS):
        result[i] = result[i] * _balances[i] / PRECISION
    return result


@internal
def _vp_rate() -> uint256:
    if block.timestamp > self.base_cache_updated + BASE_CACHE_EXPIRES:
        vprice: uint256 = Curve(BASE_POOL).get_virtual_price()
        self.base_virtual_price = vprice
        self.base_cache_updated = block.timestamp
        return vprice
    else:
        return self.base_virtual_price


@internal
@view
def _vp_rate_ro() -> uint256:
    if block.timestamp > self.base_cache_updated + BASE_CACHE_EXPIRES:
        return Curve(BASE_POOL).get_virtual_price()
    else:
        return self.base_virtual_price


@pure
@internal
def get_D(xp: uint256[N_COINS], amp: uint256) -> uint256:
    S: uint256 = 0
    Dprev: uint256 = 0
    for _x in xp:
        S += _x
    if S == 0:
        return 0

    D: uint256 = S
    Ann: uint256 = amp * N_COINS
    for _i in range(255):
        D_P: uint256 = D
        for _x in xp:
            D_P = D_P * D / (_x * N_COINS)  # If division by 0, this will be borked: only withdrawal will work. And that is good
        Dprev = D
        D = (Ann * S / A_PRECISION + D_P * N_COINS) * D / ((Ann - A_PRECISION) * D / A_PRECISION + (N_COINS + 1) * D_P)
        # Equality with the precision of 1
        if D > Dprev:
            if D - Dprev <= 1:
                return D
        else:
            if Dprev - D <= 1:
                return D
    # convergence typically occurs in 4 rounds or less, this should be unreachable!
    # if it does happen the pool is borked and LPs can withdraw via `remove_liquidity`
    raise


@view
@internal
def get_D_mem(_rates: uint256[N_COINS], _balances: uint256[N_COINS], amp: uint256) -> uint256:
    xp: uint256[N_COINS] = self._xp_mem(_rates, _balances)
    return self.get_D(xp, amp)


@view
@external
def get_virtual_price() -> uint256:
    """
    @notice The current virtual price of the pool LP token
    @dev Useful for calculating profits
    @return LP token virtual price normalized to 1e18
    """
    amp: uint256 = self._A()
    vp_rate: uint256 = self._vp_rate_ro()
    xp: uint256[N_COINS] = self._xp(vp_rate)
    D: uint256 = self.get_D(xp, amp)
    # D is in the units similar to DAI (e.g. converted to precision 1e18)
    # When balanced, D = n * x_u - total virtual value of the portfolio
    return D * PRECISION / self.totalSupply


@view
@external
def calc_token_amount(amounts: uint256[N_COINS], is_deposit: bool) -> uint256:
    """
    @notice Calculate addition or reduction in token supply from a deposit or withdrawal
    @dev This calculation accounts for slippage, but not fees.
         Needed to prevent front-running, not for precise calculations!
    @param amounts Amount of each coin being deposited
    @param is_deposit set True for deposits, False for withdrawals
    @return Expected amount of LP tokens received
    """
    amp: uint256 = self._A()
    rates: uint256[N_COINS] = [self.rate, self._vp_rate_ro()]
    _balances: uint256[N_COINS] = self.balances
    D0: uint256 = self.get_D_mem(rates, _balances, amp)
    for i in range(N_COINS):
        if is_deposit:
            _balances[i] += amounts[i]
        else:
            _balances[i] -= amounts[i]
    D1: uint256 = self.get_D_mem(rates, _balances, amp)
    diff: uint256 = 0
    if is_deposit:
        diff = D1 - D0
    else:
        diff = D0 - D1
    return diff * self.totalSupply / D0


@external
@nonreentrant('lock')
def add_liquidity(amounts: uint256[N_COINS], min_mint_amount: uint256) -> uint256:
    """
    @notice Deposit coins into the pool
    @param amounts List of amounts of coins to deposit
    @param min_mint_amount Minimum amount of LP tokens to mint from the deposit
    @return Amount of LP tokens received by depositing
    """

    amp: uint256 = self._A()
    rates: uint256[N_COINS] = [self.rate, self._vp_rate()]
    token_supply: uint256 = self.totalSupply

    # Initial invariant
    D0: uint256 = 0
    old_balances: uint256[N_COINS] = self.balances
    if token_supply > 0:
        D0 = self.get_D_mem(rates, old_balances, amp)
    new_balances: uint256[N_COINS] = old_balances

    for i in range(N_COINS):
        if token_supply == 0:
            assert amounts[i] > 0  # dev: initial deposit requires all coins
        # balances store amounts of c-tokens
        new_balances[i] = old_balances[i] + amounts[i]

    # Invariant after change
    D1: uint256 = self.get_D_mem(rates, new_balances, amp)
    assert D1 > D0

    # We need to recalculate the invariant accounting for fees
    # to calculate fair user's share
    fees: uint256[N_COINS] = empty(uint256[N_COINS])
    mint_amount: uint256 = 0
    if token_supply > 0:
        # Only account for fees if we are not the first to deposit
        base_fee: uint256 = self.fee * N_COINS / (4 * (N_COINS - 1))
        for i in range(N_COINS):
            ideal_balance: uint256 = D1 * old_balances[i] / D0
            difference: uint256 = 0
            new_balance: uint256 = new_balances[i]
            if ideal_balance > new_balance:
                difference = ideal_balance - new_balance
            else:
                difference = new_balance - ideal_balance
            fees[i] = base_fee * difference / FEE_DENOMINATOR
            self.balances[i] = new_balance - (fees[i] * ADMIN_FEE / FEE_DENOMINATOR)
            new_balances[i] -= fees[i]
        D2: uint256 = self.get_D_mem(rates, new_balances, amp)
        mint_amount = token_supply * (D2 - D0) / D0
    else:
        self.balances = new_balances
        mint_amount = D1  # Take the dust if there was any

    assert mint_amount >= min_mint_amount, "Slippage screwed you"

    # Take coins from the sender
    for i in range(N_COINS):
        if amounts[i] > 0:
            ERC20(self.coins[i]).transferFrom(msg.sender, self, amounts[i])  # dev: failed transfer

    # Mint pool tokens
    self.balanceOf[msg.sender] += mint_amount
    log Transfer(ZERO_ADDRESS, msg.sender, mint_amount)

    log AddLiquidity(msg.sender, amounts, fees, D1, token_supply + mint_amount)

    return mint_amount


@view
@internal
def get_y(i: int128, j: int128, x: uint256, xp_: uint256[N_COINS]) -> uint256:
    # x in the input is converted to the same price/precision

    assert i != j       # dev: same coin
    assert j >= 0       # dev: j below zero
    assert j < N_COINS  # dev: j above N_COINS

    # should be unreachable, but good for safety
    assert i >= 0
    assert i < N_COINS

    amp: uint256 = self._A()
    D: uint256 = self.get_D(xp_, amp)

    S_: uint256 = 0
    _x: uint256 = 0
    y_prev: uint256 = 0
    c: uint256 = D
    Ann: uint256 = amp * N_COINS

    for _i in range(N_COINS):
        if _i == i:
            _x = x
        elif _i != j:
            _x = xp_[_i]
        else:
            continue
        S_ += _x
        c = c * D / (_x * N_COINS)
    c = c * D * A_PRECISION / (Ann * N_COINS)
    b: uint256 = S_ + D * A_PRECISION / Ann  # - D
    y: uint256 = D
    for _i in range(255):
        y_prev = y
        y = (y*y + c) / (2 * y + b - D)
        # Equality with the precision of 1
        if y > y_prev:
            if y - y_prev <= 1:
                return y
        else:
            if y_prev - y <= 1:
                return y
    raise


@view
@external
def get_dy(i: int128, j: int128, dx: uint256) -> uint256:
    # dx and dy in c-units
    rates: uint256[N_COINS] = [self.rate, self._vp_rate_ro()]
    xp: uint256[N_COINS] = self._xp(rates[MAX_COIN])

    x: uint256 = xp[i] + (dx * rates[i] / PRECISION)
    y: uint256 = self.get_y(i, j, x, xp)
    dy: uint256 = xp[j] - y - 1
    _fee: uint256 = self.fee * dy / FEE_DENOMINATOR
    return (dy - _fee) * PRECISION / rates[j]


@view
@external
def get_dy_underlying(i: int128, j: int128, dx: uint256) -> uint256:
    # dx and dy in underlying units
    vp_rate: uint256 = self._vp_rate_ro()
    xp: uint256[N_COINS] = self._xp(vp_rate)
    _base_pool: address = BASE_POOL

    # Use base_i or base_j if they are >= 0
    base_i: int128 = i - MAX_COIN
    base_j: int128 = j - MAX_COIN
    meta_i: int128 = MAX_COIN
    meta_j: int128 = MAX_COIN
    if base_i < 0:
        meta_i = i
    if base_j < 0:
        meta_j = j

    x: uint256 = 0
    if base_i < 0:
        x = xp[i] + dx * self.rate * 10**18
    else:
        if base_j < 0:
            # i is from BasePool
            # At first, get the amount of pool tokens
            base_inputs: uint256[BASE_N_COINS] = empty(uint256[BASE_N_COINS])
            base_inputs[base_i] = dx
            # Token amount transformed to underlying "dollars"
            x = Curve(_base_pool).calc_token_amount(base_inputs, True) * vp_rate / PRECISION
            # Accounting for deposit/withdraw fees approximately
            x -= x * Curve(_base_pool).fee() / (2 * FEE_DENOMINATOR)
            # Adding number of pool tokens
            x += xp[MAX_COIN]
        else:
            # If both are from the base pool
            return Curve(_base_pool).get_dy(base_i, base_j, dx)

    # This pool is involved only when in-pool assets are used
    y: uint256 = self.get_y(meta_i, meta_j, x, xp)
    dy: uint256 = xp[meta_j] - y - 1
    dy = (dy - self.fee * dy / FEE_DENOMINATOR)

    # If output is going via the metapool
    if base_j < 0:
        dy /= 10**18
    else:
        # j is from BasePool
        # The fee is already accounted for
        dy = Curve(_base_pool).calc_withdraw_one_coin(dy * PRECISION / vp_rate, base_j)

    return dy


@external
@nonreentrant('lock')
def exchange(i: int128, j: int128, dx: uint256, min_dy: uint256) -> uint256:
    """
    @notice Perform an exchange between two coins
    @dev Index values can be found via the `coins` public getter method
    @param i Index value for the coin to send
    @param j Index valie of the coin to recieve
    @param dx Amount of `i` being exchanged
    @param min_dy Minimum amount of `j` to receive
    @return Actual amount of `j` received
    """
    rates: uint256[N_COINS] = [self.rate, self._vp_rate()]

    old_balances: uint256[N_COINS] = self.balances
    xp: uint256[N_COINS] = self._xp_mem(rates, old_balances)

    x: uint256 = xp[i] + dx * rates[i] / PRECISION
    y: uint256 = self.get_y(i, j, x, xp)

    dy: uint256 = xp[j] - y - 1  # -1 just in case there were some rounding errors
    dy_fee: uint256 = dy * self.fee / FEE_DENOMINATOR

    # Convert all to real units
    dy = (dy - dy_fee) * PRECISION / rates[j]
    assert dy >= min_dy, "Too few coins in result"

    dy_admin_fee: uint256 = dy_fee * ADMIN_FEE / FEE_DENOMINATOR
    dy_admin_fee = dy_admin_fee * PRECISION / rates[j]

    # Change balances exactly in same way as we change actual ERC20 coin amounts
    self.balances[i] = old_balances[i] + dx
    # When rounding errors happen, we undercharge admin fee in favor of LP
    self.balances[j] = old_balances[j] - dy - dy_admin_fee

    ERC20(self.coins[i]).transferFrom(msg.sender, self, dx)
    ERC20(self.coins[j]).transfer(msg.sender, dy)

    log TokenExchange(msg.sender, i, dx, j, dy)

    return dy


@external
@nonreentrant('lock')
def exchange_underlying(i: int128, j: int128, dx: uint256, min_dy: uint256) -> uint256:
    """
    @notice Perform an exchange between two underlying coins
    @dev Index values can be found via the `underlying_coins` public getter method
    @param i Index value for the underlying coin to send
    @param j Index valie of the underlying coin to recieve
    @param dx Amount of `i` being exchanged
    @param min_dy Minimum amount of `j` to receive
    @return Actual amount of `j` received
    """
    rates: uint256[N_COINS] = [self.rate, self._vp_rate()]
    _base_pool: address = BASE_POOL

    # Use base_i or base_j if they are >= 0
    base_i: int128 = i - MAX_COIN
    base_j: int128 = j - MAX_COIN
    meta_i: int128 = MAX_COIN
    meta_j: int128 = MAX_COIN
    if base_i < 0:
        meta_i = i
    if base_j < 0:
        meta_j = j
    dy: uint256 = 0

    # Addresses for input and output coins
    base_coins: address[3] = BASE_COINS
    input_coin: address = ZERO_ADDRESS
    if base_i < 0:
        input_coin = self.coins[i]
    else:
        input_coin = base_coins[base_i]
    output_coin: address = ZERO_ADDRESS
    if base_j < 0:
        output_coin = self.coins[j]
    else:
        output_coin = base_coins[base_j]

    # Handle potential Tether fees
    dx_w_fee: uint256 = dx
    if j == 4:
        dx_w_fee = ERC20(input_coin).balanceOf(self)

    ERC20(input_coin).transferFrom(msg.sender, self, dx)

    # Handle potential Tether fees
    if j == 4:
        dx_w_fee = ERC20(input_coin).balanceOf(self) - dx_w_fee

    if base_i < 0 or base_j < 0:
        old_balances: uint256[N_COINS] = self.balances
        xp: uint256[N_COINS] = self._xp_mem(rates, old_balances)

        x: uint256 = 0
        if base_i < 0:
            x = xp[i] + dx_w_fee * rates[i] / PRECISION
        else:
            # i is from BasePool
            # At first, get the amount of pool tokens
            base_inputs: uint256[BASE_N_COINS] = empty(uint256[BASE_N_COINS])
            base_inputs[base_i] = dx_w_fee
            coin_i: address = self.coins[MAX_COIN]
            # Deposit and measure delta
            x = ERC20(coin_i).balanceOf(self)
            Curve(_base_pool).add_liquidity(base_inputs, 0)
            # Need to convert pool token to "virtual" units using rates
            # dx is also different now
            dx_w_fee = ERC20(coin_i).balanceOf(self) - x
            x = dx_w_fee * rates[MAX_COIN] / PRECISION
            # Adding number of pool tokens
            x += xp[MAX_COIN]

        y: uint256 = self.get_y(meta_i, meta_j, x, xp)

        # Either a real coin or token
        dy = xp[meta_j] - y - 1  # -1 just in case there were some rounding errors
        dy_fee: uint256 = dy * self.fee / FEE_DENOMINATOR

        # Convert all to real units
        # Works for both pool coins and real coins
        dy = (dy - dy_fee) * PRECISION / rates[meta_j]

        dy_admin_fee: uint256 = dy_fee * ADMIN_FEE / FEE_DENOMINATOR
        dy_admin_fee = dy_admin_fee * PRECISION / rates[meta_j]

        # Change balances exactly in same way as we change actual ERC20 coin amounts
        self.balances[meta_i] = old_balances[meta_i] + dx_w_fee
        # When rounding errors happen, we undercharge admin fee in favor of LP
        self.balances[meta_j] = old_balances[meta_j] - dy - dy_admin_fee

        # Withdraw from the base pool if needed
        if base_j >= 0:
            out_amount: uint256 = ERC20(output_coin).balanceOf(self)
            Curve(_base_pool).remove_liquidity_one_coin(dy, base_j, 0)
            dy = ERC20(output_coin).balanceOf(self) - out_amount

        assert dy >= min_dy, "Too few coins in result"

    else:
        # If both are from the base pool
        dy = ERC20(output_coin).balanceOf(self)
        Curve(_base_pool).exchange(base_i, base_j, dx_w_fee, min_dy)
        dy = ERC20(output_coin).balanceOf(self) - dy

    ERC20(output_coin).transfer(msg.sender, dy)

    log TokenExchangeUnderlying(msg.sender, i, dx, j, dy)

    return dy


@external
@nonreentrant('lock')
def remove_liquidity(_amount: uint256, min_amounts: uint256[N_COINS]) -> uint256[N_COINS]:
    """
    @notice Withdraw coins from the pool
    @dev Withdrawal amounts are based on current deposit ratios
    @param _amount Quantity of LP tokens to burn in the withdrawal
    @param min_amounts Minimum amounts of underlying coins to receive
    @return List of amounts of coins that were withdrawn
    """
    total_supply: uint256 = self.totalSupply
    amounts: uint256[N_COINS] = empty(uint256[N_COINS])

    for i in range(N_COINS):
        value: uint256 = self.balances[i] * _amount / total_supply
        assert value >= min_amounts[i], "Too few coins in result"
        self.balances[i] -= value
        amounts[i] = value
        ERC20(self.coins[i]).transfer(msg.sender, value)

    self.balanceOf[msg.sender] -= _amount
    log Transfer(msg.sender, ZERO_ADDRESS, _amount)

    log RemoveLiquidity(msg.sender, amounts, empty(uint256[N_COINS]), total_supply - _amount)

    return amounts


@external
@nonreentrant('lock')
def remove_liquidity_imbalance(amounts: uint256[N_COINS], max_burn_amount: uint256) -> uint256:
    """
    @notice Withdraw coins from the pool in an imbalanced amount
    @param amounts List of amounts of underlying coins to withdraw
    @param max_burn_amount Maximum amount of LP token to burn in the withdrawal
    @return Actual amount of the LP token burned in the withdrawal
    """

    amp: uint256 = self._A()
    rates: uint256[N_COINS] = [self.rate, self._vp_rate()]
    old_balances: uint256[N_COINS] = self.balances
    D0: uint256 = self.get_D_mem(rates, old_balances, amp)

    new_balances: uint256[N_COINS] = old_balances
    for i in range(N_COINS):
        new_balances[i] -= amounts[i]
    D1: uint256 = self.get_D_mem(rates, new_balances, amp)

    fees: uint256[N_COINS] = empty(uint256[N_COINS])
    base_fee: uint256 = self.fee * N_COINS / (4 * (N_COINS - 1))
    for i in range(N_COINS):
        ideal_balance: uint256 = D1 * old_balances[i] / D0
        difference: uint256 = 0
        new_balance: uint256 = new_balances[i]
        if ideal_balance > new_balance:
            difference = ideal_balance - new_balance
        else:
            difference = new_balance - ideal_balance
        fees[i] = base_fee * difference / FEE_DENOMINATOR
        self.balances[i] = new_balance - (fees[i] * ADMIN_FEE / FEE_DENOMINATOR)
        new_balances[i] -= fees[i]
    D2: uint256 = self.get_D_mem(rates, new_balances, amp)

    token_supply: uint256 = self.totalSupply
    token_amount: uint256 = (D0 - D2) * token_supply / D0
    assert token_amount != 0  # dev: zero tokens burned
    token_amount += 1  # In case of rounding errors - make it unfavorable for the "attacker"
    assert token_amount <= max_burn_amount, "Slippage screwed you"

    self.balanceOf[msg.sender] -= token_amount
    log Transfer(msg.sender, ZERO_ADDRESS, token_amount)

    for i in range(N_COINS):
        if amounts[i] != 0:
            ERC20(self.coins[i]).transfer(msg.sender, amounts[i])

    log RemoveLiquidityImbalance(msg.sender, amounts, fees, D1, token_supply - token_amount)

    return token_amount


@view
@internal
def get_y_D(A_: uint256, i: int128, xp: uint256[N_COINS], D: uint256) -> uint256:
    """
    Calculate x[i] if one reduces D from being calculated for xp to D

    Done by solving quadratic equation iteratively.
    x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
    x_1**2 + b*x_1 = c

    x_1 = (x_1**2 + c) / (2*x_1 + b)
    """
    # x in the input is converted to the same price/precision

    assert i >= 0  # dev: i below zero
    assert i < N_COINS  # dev: i above N_COINS

    S_: uint256 = 0
    _x: uint256 = 0
    y_prev: uint256 = 0

    c: uint256 = D
    Ann: uint256 = A_ * N_COINS

    for _i in range(N_COINS):
        if _i != i:
            _x = xp[_i]
        else:
            continue
        S_ += _x
        c = c * D / (_x * N_COINS)
    c = c * D * A_PRECISION / (Ann * N_COINS)
    b: uint256 = S_ + D * A_PRECISION / Ann
    y: uint256 = D
    for _i in range(255):
        y_prev = y
        y = (y*y + c) / (2 * y + b - D)
        # Equality with the precision of 1
        if y > y_prev:
            if y - y_prev <= 1:
                return y
        else:
            if y_prev - y <= 1:
                return y
    raise


@view
@internal
def _calc_withdraw_one_coin(_token_amount: uint256, i: int128, vp_rate: uint256) -> (uint256, uint256, uint256):
    # First, need to calculate
    # * Get current D
    # * Solve Eqn against y_i for D - _token_amount
    amp: uint256 = self._A()
    xp: uint256[N_COINS] = self._xp(vp_rate)
    D0: uint256 = self.get_D(xp, amp)

    total_supply: uint256 = self.totalSupply
    D1: uint256 = D0 - _token_amount * D0 / total_supply
    new_y: uint256 = self.get_y_D(amp, i, xp, D1)

    _fee: uint256 = self.fee * N_COINS / (4 * (N_COINS - 1))
    rates: uint256[N_COINS] = [self.rate, vp_rate]

    xp_reduced: uint256[N_COINS] = xp
    dy_0: uint256 = (xp[i] - new_y) * PRECISION / rates[i]  # w/o fees

    for j in range(N_COINS):
        dx_expected: uint256 = 0
        if j == i:
            dx_expected = xp[j] * D1 / D0 - new_y
        else:
            dx_expected = xp[j] - xp[j] * D1 / D0
        xp_reduced[j] -= _fee * dx_expected / FEE_DENOMINATOR

    dy: uint256 = xp_reduced[i] - self.get_y_D(amp, i, xp_reduced, D1)
    dy = (dy - 1) * PRECISION / rates[i]  # Withdraw less to account for rounding errors

    return dy, dy_0 - dy, total_supply


@view
@external
def calc_withdraw_one_coin(_token_amount: uint256, i: int128) -> uint256:
    """
    @notice Calculate the amount received when withdrawing a single coin
    @param _token_amount Amount of LP tokens to burn in the withdrawal
    @param i Index value of the coin to withdraw
    @return Amount of coin received
    """
    vp_rate: uint256 = self._vp_rate_ro()
    return self._calc_withdraw_one_coin(_token_amount, i, vp_rate)[0]


@external
@nonreentrant('lock')
def remove_liquidity_one_coin(_token_amount: uint256, i: int128, _min_amount: uint256) -> uint256:
    """
    @notice Withdraw a single coin from the pool
    @param _token_amount Amount of LP tokens to burn in the withdrawal
    @param i Index value of the coin to withdraw
    @param _min_amount Minimum amount of coin to receive
    @return Amount of coin received
    """

    vp_rate: uint256 = self._vp_rate()
    dy: uint256 = 0
    dy_fee: uint256 = 0
    total_supply: uint256 = 0
    dy, dy_fee, total_supply = self._calc_withdraw_one_coin(_token_amount, i, vp_rate)
    assert dy >= _min_amount, "Not enough coins removed"

    self.balances[i] -= (dy + dy_fee * ADMIN_FEE / FEE_DENOMINATOR)
    self.balanceOf[msg.sender] -= _token_amount
    log Transfer(msg.sender, ZERO_ADDRESS, _token_amount)

    ERC20(self.coins[i]).transfer(msg.sender, dy)


    log RemoveLiquidityOne(msg.sender, _token_amount, dy, total_supply - _token_amount)

    return dy


@external
def ramp_A(_future_A: uint256, _future_time: uint256):
    assert msg.sender == self.owner  # dev: only owner
    assert block.timestamp >= self.initial_A_time + MIN_RAMP_TIME
    assert _future_time >= block.timestamp + MIN_RAMP_TIME  # dev: insufficient time

    _initial_A: uint256 = self._A()
    _future_A_p: uint256 = _future_A * A_PRECISION

    assert _future_A > 0 and _future_A < MAX_A
    if _future_A_p < _initial_A:
        assert _future_A_p * MAX_A_CHANGE >= _initial_A
    else:
        assert _future_A_p <= _initial_A * MAX_A_CHANGE

    self.initial_A = _initial_A
    self.future_A = _future_A_p
    self.initial_A_time = block.timestamp
    self.future_A_time = _future_time

    log RampA(_initial_A, _future_A_p, block.timestamp, _future_time)


@external
def stop_ramp_A():
    assert msg.sender == self.owner  # dev: only owner

    current_A: uint256 = self._A()
    self.initial_A = current_A
    self.future_A = current_A
    self.initial_A_time = block.timestamp
    self.future_A_time = block.timestamp
    # now (block.timestamp < t1) is always False, so we return saved A

    log StopRampA(current_A, block.timestamp)


@view
@external
def admin_balances(i: uint256) -> uint256:
    return ERC20(self.coins[i]).balanceOf(self) - self.balances[i]


@external
def withdraw_admin_fees():
    rates: uint256[N_COINS] = [self.rate, self._vp_rate()]

    old_balances: uint256[N_COINS] = self.balances
    xp: uint256[N_COINS] = self._xp_mem(rates, old_balances)

    dx: uint256 = ERC20(self.coins[0]).balanceOf(self) - old_balances[0]
    x: uint256 = xp[0] + dx * rates[0] / PRECISION
    y: uint256 = self.get_y(0, 1, x, xp)

    dy: uint256 = xp[1] - y - 1  # -1 just in case there were some rounding errors
    dy_fee: uint256 = dy * self.fee / FEE_DENOMINATOR

    # Convert all to real units
    dy = (dy - dy_fee) * PRECISION / rates[1]
    dy_admin_fee: uint256 = dy_fee * ADMIN_FEE / FEE_DENOMINATOR
    dy_admin_fee = dy_admin_fee * PRECISION / rates[1]

    # Change balances exactly in same way as we change actual ERC20 coin amounts
    self.balances = [old_balances[0] + dx, old_balances[1] - dy - dy_admin_fee]
    # When rounding errors happen, we undercharge admin fee in favor of LP

    new_balance: uint256 = old_balances[1] - dy - dy_admin_fee
    self.balances = [old_balances[0] + dx, new_balance]
    coin: address = self.coins[1]

    claimable_fee: uint256 = ERC20(coin).balanceOf(self) - new_balance
    ERC20(coin).transfer(FEE_RECEIVER, claimable_fee)


@view
@external
def decimals() -> uint256:
    """
    @notice Get the number of decimals for this token
    @dev Implemented as a view method to reduce gas costs
    @return uint256 decimal places
    """
    return 18


@external
def transfer(_to : address, _value : uint256) -> bool:
    """
    @dev Transfer token for a specified address
    @param _to The address to transfer to.
    @param _value The amount to be transferred.
    """
    # NOTE: vyper does not allow underflows
    #       so the following subtraction would revert on insufficient balance
    self.balanceOf[msg.sender] -= _value
    self.balanceOf[_to] += _value

    log Transfer(msg.sender, _to, _value)
    return True


@external
def transferFrom(_from : address, _to : address, _value : uint256) -> bool:
    """
     @dev Transfer tokens from one address to another.
     @param _from address The address which you want to send tokens from
     @param _to address The address which you want to transfer to
     @param _value uint256 the amount of tokens to be transferred
    """
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value

    _allowance: uint256 = self.allowance[_from][msg.sender]
    if _allowance != MAX_UINT256:
        self.allowance[_from][msg.sender] = _allowance - _value

    log Transfer(_from, _to, _value)
    return True


@external
def approve(_spender : address, _value : uint256) -> bool:
    """
    @notice Approve the passed address to transfer the specified amount of
            tokens on behalf of msg.sender
    @dev Beware that changing an allowance via this method brings the risk
         that someone may use both the old and new allowance by unfortunate
         transaction ordering. This may be mitigated with the use of
         {increaseAllowance} and {decreaseAllowance}.
         https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    @param _spender The address which will transfer the funds
    @param _value The amount of tokens that may be transferred
    @return bool success
    """
    self.allowance[msg.sender][_spender] = _value

    log Approval(msg.sender, _spender, _value)
    return True
