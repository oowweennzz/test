// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableMapUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

contract Bbs is Initializable,AccessControlEnumerableUpgradeable,ReentrancyGuardUpgradeable{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    CountersUpgradeable.Counter private noteCounter; //笔记计数

    using EnumerableMapUpgradeable for EnumerableMapUpgradeable.AddressToUintMap;
    EnumerableMapUpgradeable.AddressToUintMap private tokenMaps; //打赏币种列表

    using SafeERC20Upgradeable for IERC20Upgradeable;

    using AddressUpgradeable for address;


    bytes32 public constant USE_ROLE = keccak256("USE_ROLE"); //激活权限

    struct Content {
        address user; //用户
        string url; //内容链接
        uint8 replyType; //0所有人可以回复，1所有人不允许回复，2关注者回复
        uint8 forwardType; //0所有人可以转发，1所有人不允许转发，2关注者转发
        uint256 create; //创建时间
    }

    //用户自身纬度
    struct UserCounts {
        uint256 follows; //关注数量
        uint256 fans;//粉丝数量
    }

    mapping(bytes32 => bool) private likeRecord; //用户点赞记录
    mapping(bytes32 => bool) private followRecord; //用户关注记录
    mapping(uint256 => Content) public contents; //发布内容
    mapping(address => UserCounts) public userCounts; //行为统计（点赞，回复，转发）
    mapping(address => string)  public info; //用户信息

    event Userinfo(
        address indexed user,
        string url,
        uint256 create
    );

    //修改发布内容事件
    event Publish(
        address indexed user,
        uint256  noteid,
        string url,
        uint8 state, // 0发布，1修改，2删除
        uint8 replyType, //0所有人可以回复，1所有人不允许回复，2关注者回复
        uint8 forwardType, //0所有人可以转发，1所有人不允许转发，2关注者转发
        uint256 create
    );

    //点赞事件
    event Like (
        address indexed user,
        uint256  noteid,
        uint8 state, // 0取消，1点赞
        uint256 create
    );

    //评论内容
    event Reply (
        address indexed user,
        uint256  noteid,
        uint256 sourceid,
        string url, //评论内容
        uint8 state, // 0取消，1评论
        uint8 replyType, //0所有人可以回复，1所有人不允许回复，2关注者回复
        uint8 forwardType, //0所有人可以转发，1所有人不允许转发，2关注者转发
        uint256 create
    );

    //转发内容
    event Forward (
        address indexed user,
        uint256  noteid,
        uint256 sourceid,
        string url, //评论内容
        uint8 state, // 0取消，1转发
        uint8 replyType, //0所有人可以回复，1所有人不允许回复，2关注者回复
        uint8 forwardType, //0所有人可以转发，1所有人不允许转发，2关注者转发
        uint256 create
    );

    //关注
    event Follow (
        address indexed user,
        address follower,
        uint8 state, // 0取消，1关注
        uint256 create
    );

    //打赏
    event Reward (
        address indexed user,
        uint256 noteid,
        address to,
        address token,
        uint256 value,
        uint256 create
    );

    //初始化合约
    function initialize() external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender()); //超管权限
        _setupRole(USE_ROLE, _msgSender());           //次级使用权限
        noteCounter.increment();                      //发布内容从1开始
    }

    //个人信息修改
    function profile(string calldata url) external  {
        info[_msgSender()] = url;
        emit Userinfo(_msgSender(),url,block.timestamp);      //log上链，链下解析
    }

    //发布内容
    function publish(string calldata url) external  returns(uint256){
        uint256 noteid = noteCounter.current();                         //取出使用的ID
        _saveContent(noteid,0,0,url);
        emit Publish(_msgSender(),noteid,url,0,0,0,block.timestamp);      //log上链，链下解析
        return noteid;
    }

    //发布内容
    function publish2(string calldata url,uint8 rType,uint8 fType) external  returns(uint256){
        uint256 noteid = noteCounter.current();                         //取出使用的ID
        _saveContent(noteid,rType,fType,url);
        emit Publish(_msgSender(),noteid,url,0,rType,fType,block.timestamp);      //log上链，链下解析
        return noteid;
    }

    //修改内容,因为激活了才能发布，这里就不需要判断是否激活了
    function updated(uint256 id,string calldata url) external {
        require(contents[id].user == _msgSender(),"not owner"); //非发布者
        contents[id].url = url;                               //链接信息存入
        contents[id].create = block.timestamp;                  //时间信息存入
        emit Publish(_msgSender(),id,url,1, contents[id].replyType,contents[id].forwardType,block.timestamp);  //log上链，链下解析
    }

    //删除内容
    function deleted(uint256 id) external {
        require(contents[id].user == _msgSender(),"not owner"); //非发布者
        contents[id].user = address(0);
        contents[id].url = "";                                  //链接信息置空
        contents[id].create = block.timestamp;                  //时间更新
        emit Publish(_msgSender(),id,"",2,contents[id].replyType,contents[id].forwardType,block.timestamp);     //log上链，链下解析
    }

    //点赞
    function like(uint256 id) public {
        require(checkLike(id) == false,"already liked");
        require(contents[id].user != address(0),"not exist");   //id是否存在
        bytes32 key = keccak256(abi.encodePacked(_msgSender(), id));
        likeRecord[key] = true;
        emit Like(_msgSender(),id, 1, block.timestamp);        //log上链，链下解析
    }

    //取消点赞
    function unLike(uint256 id) external {
        require(contents[id].user != address(0),"not exist");   //id是否存在
        bytes32 key = keccak256(abi.encodePacked(_msgSender(), id));
        likeRecord[key] = false;                //点赞-1
        emit Like(_msgSender(),id, 0, block.timestamp);        //log上链，链下解析
    }

    //转发
    function forward(uint256 id,string memory url) public {
        require(checkForward(id) == true,"unable to forward");
        require(contents[id].user != address(0),"not exist");   //id是否存在
        uint256 noteid = noteCounter.current();
        uint8 rType = _getReplyType(contents[id].replyType);
        uint8 fType = _getForwardType(contents[id].forwardType);
        _saveContent(noteid,rType,fType,url);
        emit Forward(_msgSender(),noteid,id,url,1,rType,fType,block.timestamp);     //log上链，链下解析
    }


    //取消转发
    function unForward(uint256 id) external {
        require(contents[id].user != address(0),"not exist");   //id是否存在
        emit Forward(_msgSender(),0,id, "",0,contents[id].replyType,contents[id].forwardType, block.timestamp);     //log上链，链下解析
    }

    //评论内容
    function reply(uint256 id,string calldata url) external {
        require(checkReply(id) == true,"unable to reply");
        require(contents[id].user != address(0),"not exist");     //id是否存在
        uint256 noteid = noteCounter.current();
        uint8 rType = 0; //所有人可以评论
        uint8 fType = _getForwardType(contents[id].forwardType);
        _saveContent(noteid,rType,fType,url);
        emit Reply(_msgSender(),noteid,id, url, 1, rType,fType,block.timestamp);
    }

    //取消评论
    function unReply(uint256 id) external {
        require(contents[id].user != address(0),"not exist");    //id是否存在
        emit Reply( _msgSender(),0,id, "", 0,contents[id].replyType,contents[id].forwardType,block.timestamp);   //log上链，链下解析
    }

    //关注事件
    function follow(address up) public {
        require(up != _msgSender(),"error address"); //不允许自己关注自己
        userCounts[up].fans = userCounts[up].fans + 1;
        userCounts[_msgSender()].follows = userCounts[_msgSender()].follows + 1;
        bytes32 key = keccak256(abi.encodePacked(_msgSender(), up));
        followRecord[key] = true;
        emit Follow(_msgSender(),up,1,block.timestamp);
    }

    //取消关注
    function unFollow(address up) external {
        userCounts[up].fans = userCounts[up].fans - 1;
        userCounts[_msgSender()].follows = userCounts[_msgSender()].follows - 1;
        bytes32 key = keccak256(abi.encodePacked(_msgSender(), up));
        followRecord[key] = false;
        emit Follow(_msgSender(),up,0,block.timestamp);
    }

    //一键三连
    function all(uint256 id,address up) external {
        if (!checkLike(id)){
            like(id);
        }
        if ((checkFollow(up))){
            follow(up);
        }
        forward(id, "");
    }

    //打赏-主链币
    function donate(uint256 id) external payable nonReentrant{
        require(msg.value > 0,"zero value");                                            //金额大于0
        address to = contents[id].user;                                               //接收者为内容发布者
        require(to != address(0),"not exist");                                          //地址不能为0
        payable(to).transfer(msg.value);                                                //金额转账
        emit Reward(_msgSender(), id,to, address(0), msg.value, block.timestamp);    //log上链，链下解析
    }

    //打赏-代币
    //注意地址需要先进行授权
    //白名单判断
    //接收者为内容发布者
    //地址不能为0
    //接收地址不允许合约地址
    //金额转账
    //log上链，链下解析
    function donateToken(uint256 id,address rawToken,uint256 amount) external {
        require(tokenMaps.contains(rawToken),"unknown token");                        
        address to = contents[id].user;                                               
        require(to != address(0),"not exist");                                         
        require(!to.isContract(), "error to"); 
        require(amount > 0, "error amount");                                          
        IERC20Upgradeable(rawToken).safeTransferFrom(_msgSender(), to, amount);
        emit Reward( _msgSender(),id,to, rawToken, amount, block.timestamp);
    }

    function extractToken(address tokenAddress) external  nonReentrant onlyRole(USE_ROLE) {
        if (tokenAddress == address(0)) {
            // Extract main chain token
            payable(_msgSender()).transfer(address(this).balance);
        }else{
            // Extract ERC20 token
            IERC20Upgradeable token = IERC20Upgradeable(tokenAddress);
            uint256 balance = token.balanceOf(address(this));
            token.safeTransfer(_msgSender(), balance);
        }
        return;
    }

    //添加打赏币种
    function addToken(address token) external onlyRole(USE_ROLE) {
        require(token != address(0),"zero address");
        require(!tokenMaps.contains(token), "already exists");  //代币已经存在不需要执行
        tokenMaps.set(token,  1);
    }

    //删除打赏币种
    function delToken(address token) external onlyRole(USE_ROLE) {
        tokenMaps.remove(token);
    }

    //获取币种列表
    function tokens() external view returns (address[] memory){
        address[] memory result = new address[](tokenMaps.length());
        for (uint256 i = 0; i < tokenMaps.length(); i++) {
            (result[i],) = tokenMaps.at(1);
        }
        return result;
    }

    //检查是否存在打赏的币种
    function checkToken(address token) external view returns (bool) {
        if (tokenMaps.contains(token)) {
            return true;
        }
        return false;
    }

    //检查是否点赞过
    function checkLike(uint256 id) public view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(_msgSender(), id));
        return likeRecord[key];
    }

    //检查是否关注过
    function checkFollow(address up) public view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(_msgSender(), up));
        return followRecord[key];
    }

    //检查是否允许回复
    function checkReply(uint256 id) public view returns (bool) {
        uint8 rType = contents[id].replyType;
        if (rType == 0) {
            return true;
        }else if (rType == 1) {
            return false;
        }else if (rType == 2) {
            address up = contents[id].user;
            if (address(0) == up) {
                return false;//不存在
            }
            if (checkFollow(up)){
                return true;
            }
            return false;
        }
        return false;
    }

    //检查是否允许回复
    function checkForward(uint256 id) public view returns (bool) {
        uint8 fType = contents[id].forwardType;
        if (fType == 0) {
            return true;
        }else if (fType == 1) {
            return false;
        }else if (fType == 2) {
            address up = contents[id].user;
            if (address(0) == up) {
                return false;//不存在
            }
            if (checkFollow(up)){
                return true;
            }
            return false;
        }
        return false;
    }

    //保存信息
    function _saveContent(uint256 noteid,uint8 rType,uint8 fType,string memory url) private {
        contents[noteid] = Content(_msgSender(),url,rType,fType,block.timestamp); //保存信息
        noteCounter.increment();
    }

    //回复的时候，二层级之后的禁止使用
    function _getReplyType(uint8 replyType) private pure returns(uint8){
        if (replyType > 2) {
            return 1;
        }
        return replyType;
    }

    //转发的时候，二层级之后的禁止使用
    function _getForwardType(uint8 forwardType) private pure returns(uint8){
        if (forwardType > 2) {
            return 1;
        }
        return forwardType;
    }
}
