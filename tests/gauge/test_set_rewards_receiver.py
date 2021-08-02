import pytest
from brownie import ZERO_ADDRESS, compile_source
from pytest import approx

REWARD = 10 ** 20
WEEK = 7 * 86400
LP_AMOUNT = 10 ** 18


code = """
# @version 0.2.7

from vyper.interfaces import ERC20

first: address
second: address

@external
def __init__(_first: address, _second: address):
    self.first = _first
    self.second = _second

@external
def claim_tokens() -> bool:
    ERC20(self.first).transfer(msg.sender, ERC20(self.first).balanceOf(self) / 2)
    ERC20(self.second).transfer(msg.sender, ERC20(self.second).balanceOf(self) / 2)

    return True
"""


@pytest.fixture(scope="module")
def reward_contract(alice, coin_a, coin_b):
    contract = compile_source(code).Vyper.deploy(coin_a, coin_b, {"from": alice})
    coin_a._mint_for_testing(contract, REWARD * 2)
    coin_b._mint_for_testing(contract, REWARD * 2)

    yield contract


@pytest.fixture(scope="module", autouse=True)
def initial_setup(alice, bob, chain, gauge, reward_contract, coin_reward, coin_a, coin_b, swap):

    sigs = f"0x{'00' * 4}{'00' * 4}{reward_contract.claim_tokens.signature[2:]}{'00' * 20}"

    gauge.set_rewards(
        reward_contract, sigs, [coin_a, coin_reward, coin_b] + [ZERO_ADDRESS] * 5, {"from": alice}
    )

    # Deposit
    swap.transfer(bob, LP_AMOUNT, {"from": alice})
    swap.approve(gauge, LP_AMOUNT, {"from": bob})
    gauge.deposit(LP_AMOUNT, {"from": bob})

    chain.sleep(WEEK)


def test_claim_one_lp(alice, bob, chain, gauge, coin_a, coin_b):
    chain.sleep(WEEK)

    gauge.set_rewards_receiver(alice, {"from": bob})

    gauge.withdraw(LP_AMOUNT, {"from": bob})
    gauge.claim_rewards({"from": bob})

    for coin in (coin_a, coin_b):
        reward = coin.balanceOf(alice)
        assert reward <= REWARD
        assert approx(REWARD, reward, 1.001 / WEEK)  # ganache-cli jitter of 1 s
