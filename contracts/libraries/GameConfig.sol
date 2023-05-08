// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../libraries/Helper.sol";
import "../interfaces/IWavGame.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library GameConfig {


    /// @notice Explain to an end user what this does
    /// @dev Explain to a developer any extra details
    function setLevel(IWavGame.Level storage uniqueLevel, IWavGame.LevelParam memory updateParam) internal  {
        uniqueLevel.requiredBurn = updateParam.requiredBurn;
        uniqueLevel.requiredMint = updateParam.requiredMint;
        uniqueLevel.prizeCutOff = updateParam.prizeCutOff;

        //  requiredBurn (should be greater than 0 and less than burnables)
        setBurnableSet(uniqueLevel, updateParam.burnableSet);
        setMintableSet(uniqueLevel, updateParam.mintableSet);
    }

    

    function setBurnableSet(IWavGame.Level storage uniqueLevel, uint256[] memory _burnableSet) internal  {
        for (uint256 i; i < _burnableSet.length;) {
            if (!EnumerableSet.contains(uniqueLevel.burnableSet, _burnableSet[i])) {
                EnumerableSet.add(uniqueLevel.burnableSet, _burnableSet[i]);
            } 
            unchecked {++i;} 
        }
    }	

    function setMintableSet(IWavGame.Level storage uniqueLevel, uint256[] memory _mintableSet) internal  {
        for (uint256 i; i < _mintableSet.length;) {
            if (!EnumerableSet.contains(uniqueLevel.mintableSet, _mintableSet[i])) {
                EnumerableSet.add(uniqueLevel.mintableSet, _mintableSet[i]);
            } 
            unchecked {++i;} 
        }
    }	

}