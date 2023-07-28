// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {IAToken} from '@aave/core-v3/contracts/interfaces/IAToken.sol';
import {BaseParaSwapAdapter} from '../../src/contracts/BaseParaSwapAdapter.sol';

library SigUtils {
  bytes32 public constant PERMIT_TYPEHASH =
    keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');

  bytes32 private constant CREDIT_DELEGATION_TYPEHASH =
    keccak256('DelegationWithSig(address delegatee,uint256 value,uint256 nonce,uint256 deadline)');

  struct Permit {
    address owner;
    address spender;
    uint256 value;
    uint256 nonce;
    uint256 deadline;
  }

  struct CreditDelegation {
    address delegatee;
    uint256 value;
    uint256 nonce;
    uint256 deadline;
  }

  // computes the hash of a permit
  function getStructHash(Permit memory _permit) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encode(
          PERMIT_TYPEHASH,
          _permit.owner,
          _permit.spender,
          _permit.value,
          _permit.nonce,
          _permit.deadline
        )
      );
  }

  // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
  function getPermitTypedDataHash(
    Permit memory _permit,
    bytes32 domainSeparator
  ) public pure returns (bytes32) {
    return
      keccak256(
        abi.encodePacked(
          '\x19\x01',
          domainSeparator,
          keccak256(
            abi.encode(
              PERMIT_TYPEHASH,
              _permit.owner,
              _permit.spender,
              _permit.value,
              _permit.nonce,
              _permit.deadline
            )
          )
        )
      );
  }

  function getCreditDelegationTypedDataHash(
    CreditDelegation memory _creditDelegation,
    bytes32 domainSeparator
  ) public pure returns (bytes32) {
    return
      keccak256(
        abi.encodePacked(
          '\x19\x01',
          domainSeparator,
          keccak256(
            abi.encode(
              CREDIT_DELEGATION_TYPEHASH,
              _creditDelegation.delegatee,
              _creditDelegation.value,
              _creditDelegation.nonce,
              _creditDelegation.deadline
            )
          )
        )
      );
  }

  // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
  function getTypedDataHash(
    Permit memory permit,
    bytes32 domainSeperator
  ) public pure returns (bytes32) {
    return keccak256(abi.encodePacked('\x19\x01', domainSeperator, getStructHash(permit)));
  }

  function getPermit(
    Vm vm,
    address user,
    uint256 userPrivateKey,
    address spender,
    address token,
    uint256 value
  ) public view returns (BaseParaSwapAdapter.PermitSignature memory) {
    Permit memory permit = Permit({
      owner: user,
      spender: spender,
      value: value,
      nonce: IAToken(token).nonces(user),
      deadline: block.timestamp + 1 days
    });
    bytes32 permitDigest = getTypedDataHash(permit, IAToken(token).DOMAIN_SEPARATOR());
    (uint8 pV, bytes32 pR, bytes32 pS) = vm.sign(userPrivateKey, permitDigest);
    return
      BaseParaSwapAdapter.PermitSignature({
        amount: permit.value,
        deadline: permit.deadline,
        v: pV,
        r: pR,
        s: pS
      });
  }
}
