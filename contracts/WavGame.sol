//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@opengsn/contracts/src/ERC2771Recipient.sol";

import "./interfaces/IWavGame.sol";
import "./interfaces/IWavContract.sol";
import "./libraries/GameConfig.sol";


contract WavGame is IWavGame, IWavContract, Ownable, ERC2771Recipient, ReentrancyGuard, ERC165 {
    using GameConfig for IWavGame.Level;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public entryFee; // In wei
    IWavContract public wavContract; 
    uint8 constant internal ENTRY_LEVEL = 1; 
    address payable public revenueContract; // Platform revenue spliting contract

    mapping(address => IWavGame.Level[]) internal ownerToGames; // Levels are 0-indexed. i.e level 1 = 0 in level

    event PaymentReleased(address to, uint256 amount);
    event Collected(address caller, address to, uint256 amount, uint256 refunded, uint256 totalMinted);
    event LeveledUp(address caller, address collector, uint8 nextLevel, uint256 totalMinted);
    event SpecialMint(address caller, address collector, uint256 id, uint256 amount);

	// Create all initial artists
	// create and map the 6 artist level / island to each artist, and define the Levels specific details per artist
    constructor(IWavContract _wavContract, address _trustedForwarder,uint256 _entryFee, address payable _revenueContract) {
        wavContract = _wavContract;
        entryFee = _entryFee;
        revenueContract = _revenueContract;
        _setTrustedForwarder(_trustedForwarder);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IWavGame).interfaceId;
    }

    /// @notice This function mints level 1 NFTs to the recipient
    /// @param _recipient The recipient of the minted NFT
    /// @param _input ids and their corresponding quantities to mint
    /// @dev This function does not support gasless, has to be called directly by user, since it requires payment in ETH and refund is possible
    function collect(address _recipient, address _owner, IDParam[] calldata _input) external payable nonReentrant {
        uint totalPayable = 0;
        uint totalMinted = 0;
        uint[] memory mintableIds; 
        uint[] memory mintableAmountPerId;

        // Create mintable IDs and valid quantity based on mintable set for base and msg.value
        for (uint i; i < _input.length;) { 
            if (EnumerableSet.contains(ownerToGames[_owner][ENTRY_LEVEL - 1].mintableSet,(_input[i].id))) {
                uint256 mintCost = _input[i].amount * entryFee;
                if ((totalPayable + mintCost) > msg.value) { // Mint only ids for sufficient value sent
                    break;
                }
                mintableIds[i] = _input[i].id;
                mintableAmountPerId[i] = _input[i].amount;
                totalMinted +=_input[i].amount;
            }
            unchecked {++i;}
        }
        // Payment split
        releasePay(totalPayable);
        // Mint NFT to _recipient
        wavContract.mintBatch(_recipient, mintableIds, mintableAmountPerId);
        // Refund any balance
        uint256 refund =  msg.value - totalPayable;
        if (totalPayable < msg.value) {
            _msgSender().call{value: refund}(""); // Failed refunds remain in contract
        }
        syncMint(ownerToGames[_owner][ENTRY_LEVEL - 1], _recipient, totalMinted);

        emit Collected(_msgSender(), _recipient, msg.value, refund, totalMinted);
    }

    function levelUp(address _owner, uint8 _nextLevel, IDParam[] memory _input) external nonReentrant {
        // Should be gasless => recipient == _msg.sender
        require(_nextLevel > ENTRY_LEVEL, "INVALID_NEXT_LEVEL");  //next level details
        IWavGame.Level storage priorLevel = ownerToGames[_owner][_nextLevel - 2]; // 0-indexed array
        IWavGame.Level storage nextLevel = ownerToGames[_owner][_nextLevel - 1]; // 0-indexed array

        uint[] memory burnableIds;
        uint[] memory burnableAmountPerId;
        uint totalBurnAmount;

        for (uint256 i = 0; i < _input.length; i++) { // ID is array, incase levelUP from 1 => 2, can have diff ids
            if (EnumerableSet.contains(nextLevel.burnableSet, [_input[i].id])) {
                burnableIds.push(_input[i].id);
                burnableAmountPerId.push(_input[i].amount);
                totalBurnAmount += _input[i].amount;
            }
        }

        require(totalBurnAmount == nextLevel.requiredBurn, "REQUIRED_BURN_NOT_MET");
        wavContract.burnBatch(_msgSender(), burnableIds, burnableAmountPerId);
        // syncBurn(priorLevel, totalBurnAmount);
        priorLevel.burnCount += burnableAmountPerId.length;

        wavContract.mint(_msgSender(), nextLevel.mintableSet.values()[0], nextLevel.requiredMint);
        syncMint(nextLevel, _msgSender(), nextLevel.mintAmount);

        emit LeveledUp(msg.sender, _msgSender(), _nextLevel, nextLevel.requiredMint);
    }

    //Returns true if msg.sender qualifies for special prize on artist collection
    function isPrizedCollector(address _owner, uint8 _level) public view returns (bool) {
        return ownerToGames[_owner][_level].collectors.contains(msg.sender);
    } 

    function fetchPrizedCollectors(address _owner, uint8 _level) public view returns (address[] memory) {
        return ownerToGames[_owner][_level].collectors.values();
    }

    // Get all artist level
    function fetchGame(address _owner) public returns (IWavGame.Level[] memory) {
        return ownerToGames[_owner];
    }

    // Get level by artist by id
    function getGameLevel(address _owner, uint256 _level) public returns (IWavGame.Level memory) {
        return ownerToGames[_owner][Helper.getLevelIndex(_level)];
    }

    // Get level by artist by id
    function getPaymentAddress() public view returns (address) {
        return revenueContract;
    }

    // Get level by artist by id
    function getFeePerMint() public view returns (uint256) {
        return entryFee;
    }

    function syncMint(Level storage level, address _recipient, uint256 _mintCount) internal {
        level.mintCount += _mintCount;
        if (level.collectors.length < 40 && !level.collectors.contains(_recipient)){
            level.collectors.add(_recipient);
        }
    }
    
    function releasePay(uint256 _totalAmount) internal  {
        (bool success, ) = revenueContract.call{value: _totalAmount}("");
        require(success, "FUNDS_RELEASE_FAILED_OR_REVERTED");
        emit PaymentReleased(revenueContract, _totalAmount);
    }

    // No checks are done for mint and batchMints, these are admin functions, minting 
    //a level-specific id through this functions may distrupt calculations on the game
    // Use special mint instead.
    function mint(address _recipient, uint _id, uint _amount) external onlyOwner {
        wavContract.mint(_recipient, _id, _amount);
    }

    function wavMint(address _recipient, address _owner, uint8 _nextLevel, uint256 _id, uint256 _amount) external onlyOwner {
        IWavGame.Level memory level = ownerToGames[_owner][_nextLevel - 1]; // 0-based index
        require(level.mintableSet[_id], "ID_NOT_MINTABLE_FOR_GIVEN_LEVEL");

        wavContract.mint(_recipient, _id, _amount);
        syncMint(level, _recipient, _amount);

        emit SpecialMint(msg.sender, _recipient, _id, _amount);
    }

    function batchMint(address _recipient, uint[] memory _ids, uint[] memory _amount) external onlyOwner {
        wavContract.mintBatch(_recipient, _ids, _amount);
    } 
    function setFeePerMint(uint256  _entryFee) external onlyOwner {
        entryFee = _entryFee;
    }

    // Get level by artist by id
    function setPaymentAddress(address _revenueContract) external onlyOwner {
        revenueContract = _revenueContract;
    }

    // This creates an owner game and populates the levels if not exist, and updates the game by adding new levels if exist.
    //Not checking for uniqueness in level configuration, only call this function when adding new levels to an owner gmae
    function setGame(address _owner, IWavGame.LevelParam[] memory _connectedLevels) public {
        for (uint256 i; i < _connectedLevels.length;) {
            ownerToGames[_owner][i].setLevel(_connectedLevels[i]);
            unchecked {++i;} 
        }
    }

    function setLevel(address _owner, uint8 _level, IWavGame.LevelParam calldata updateParam) external onlyOwner {
        ownerToGames[_owner][Helper.getLevelIndex(_level)].setLevel(updateParam);
    }

    function setRequiredBurn(address _owner, uint8 _level, uint8 _requiredBurn) external onlyOwner {
        ownerToGames[_owner][Helper.getLevelIndex(_level)].requiredBurn = _requiredBurn;
    }

    function setRequiredMint(address _owner, uint8 _level, uint8 _requiredMint) external onlyOwner {
        ownerToGames[_owner][Helper.getLevelIndex(_level)].requiredMint = _requiredMint;
    }

    function setPrizeCutOff(address _owner, uint8 _level, uint8 _prizeCutOff) external onlyOwner {
        ownerToGames[_owner][Helper.getLevelIndex(_level)].prizeCutOff = _prizeCutOff;
    }

    function setRequiredMintID(address _owner, uint8 _level, uint8 _requiredMintID) external onlyOwner {
        ownerToGames[_owner][Helper.getLevelIndex(_level)].requiredMintID = _requiredMintID;
    }

    function setBurnableSet(address _owner, uint8 _level, uint256[] calldata _burnableSet) external onlyOwner {
        for (uint256 i; i < _burnableSet.length;) {
            if (!ownerToGames[_owner][Helper.getLevelIndex(_level)].burnableSet.contains(_burnableSet[i])) {
                ownerToGames[_owner][Helper.getLevelIndex(_level)].burnableSet.add(_burnableSet[i]);
            } 
            unchecked {++i;} 
        }
    }	

    function setMintableSet(address _owner, uint8 _level, uint256[] calldata _mintableSet) external onlyOwner {
        for (uint256 i; i < _mintableSet.length;) {
            ownerToGames[_owner][Helper.getLevelIndex(_level)].mintableSet[_mintableSet[i]] = true;
            unchecked {++i;} 
        }
    }	


    function setTrustedForwarder(address _trustedForwarder) public onlyOwner {
        _setTrustedForwarder(_trustedForwarder);
    }
    
    function _msgSender() internal view virtual override(Context, ERC2771Recipient) returns (address sender) {
        return ERC2771Recipient._msgSender();
    }

    function _msgData() internal view virtual override(Context, ERC2771Recipient) returns (bytes calldata) {
        return ERC2771Recipient._msgData();
    }
}