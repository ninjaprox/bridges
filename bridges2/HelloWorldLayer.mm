#import "HelloWorldLayer.h"
#import "BridgeNode.h"
#import "HouseNode.h"
#import "BridgeColors.h"
#import "Level.h"

//#define PTM_RATIO 32.0

@interface HelloWorldLayer()
    @property (nonatomic, retain, readwrite) NSString *currentLevelPath;
@end

@implementation HelloWorldLayer


+ (id)scene {
    
    CCScene *scene = [CCScene node];
    HelloWorldLayer *layer = [HelloWorldLayer node];
    layer.tag = LEVEL;
    [scene addChild:layer];
    return scene;
    
}

- (id)init {
    
    if( (self=[super initWithColor:ccc4(255,255,255,255)] )) {
        
        director_ = (CCDirectorIOS*) [CCDirector sharedDirector];
        
        _inCross = false;
        
        b2Vec2 gravity = b2Vec2(0.0f, 0.0f);
        bool doSleep = false;
        _world = new b2World(gravity);
        _world->SetAllowSleeping(doSleep);
        
        [self schedule:@selector(tick:)];
        
        // Enable debug draw
        _debugDraw = new GLESDebugDraw( PTM_RATIO );
        _world->SetDebugDraw(_debugDraw);
        
        uint32 flags = 0;
        flags += b2Draw::e_shapeBit;
        _debugDraw->SetFlags(flags);
        
        // Create contact listener
        _contactListener = new MyContactListener();
        _world->SetContactListener(_contactListener);
        
        // Create our sprite sheet and frame cache
        _spriteSheet = [[CCSpriteBatchNode batchNodeWithFile:@"octosprite.png"
                                                    capacity:2] retain];
        [[CCSpriteFrameCache sharedSpriteFrameCache]
         addSpriteFramesWithFile:@"octosprite.plist"];
        [self addChild:_spriteSheet];
        
        _layerMgr = [[LayerMgr alloc] initWithSpriteSheet:_spriteSheet:_world];
        
        //        [self spawnPlayer];
        
        self.isTouchEnabled = YES;
    }
    return self;
    
}

-(void)readLevel {
    NSString *path = [[NSBundle mainBundle] bundlePath];
    NSString *jsonPath = [path stringByAppendingPathComponent:self.currentLevelPath];
    NSString *jsonString = [NSString stringWithContentsOfFile:jsonPath encoding:NSUTF8StringEncoding error:nil];
    
    self.currentLevel = [[Level alloc] initWithJson:jsonString: _layerMgr];
    
 //   [level.rivers makeObjectsPerformSelector:@selector(addSprite:)];
    
    [self.currentLevel addSprites];
    
    
    //[level dealloc];
}

-(void)reset {
    _hasInit = false;
    [self removeAllChildrenWithCleanup:true];
    
    [self.currentLevel dealloc];
    self.currentLevelPath = nil;
}

-(void)setLevel:(NSString*) path {
    if (self.currentLevelPath && ![self.currentLevelPath isEqualToString:path]) {
        [self reset];
    }
    
    self.currentLevelPath = path;
    
    /*
     * The first time we run we don't have the window dimensions
     * so we can't draw yet and we wait to add the level until the 
     * first draw.  After that we have the dimensions so we can 
     * just set the new level.
     */
    if (_hasInit) {
        [self readLevel];
    }
}

-(void)draw {
    
    [super draw];
    
    CGSize s = [[CCDirector sharedDirector] winSize];
    
    ccDrawSolidRect( ccp(0, 0), ccp(s.width, s.height), ccc4f(255, 255, 255, 255) );
    
    if (!_hasInit) {
        /*
         * The director doesn't know the window width correctly
         * until we do the first draw so we need to delay adding
         * our objects which rely on knowing the dimensions of
         * the window until that happens.
         */
        _layerMgr.tileSize = CGSizeMake(s.height / 28, s.height / 28);
        [self readLevel];
       // [self addRivers];
        
        _hasInit = true;
    }
    
//     _world->DrawDebugData();
}


- (void)tick:(ccTime)dt {
    if (_inCross) {
        /*
         * We get a lot of collisions when crossing a bridge
         * and we just want to ignore them until we're done.
         */
        return;
    }
    
    _world->Step(dt, 10, 10);
    for(b2Body *b = _world->GetBodyList(); b; b=b->GetNext()) {
        if (b->GetUserData() != NULL) {
            CCSprite *sprite = (CCSprite *)b->GetUserData();
            
            b2Vec2 b2Position = b2Vec2(sprite.position.x/PTM_RATIO,
                                       sprite.position.y/PTM_RATIO);
            float32 b2Angle = -1 * CC_DEGREES_TO_RADIANS(sprite.rotation);
            
            b->SetTransform(b2Position, b2Angle);
        }
    }
    
    //    std::vector<b2Body *>toDestroy;
    std::vector<MyContact>::iterator pos;
    for(pos = _contactListener->_contacts.begin();
        pos != _contactListener->_contacts.end(); ++pos) {
        MyContact contact = *pos;
        
        b2Body *bodyA = contact.fixtureA->GetBody();
        b2Body *bodyB = contact.fixtureB->GetBody();
        if (bodyA->GetUserData() != NULL && bodyB->GetUserData() != NULL) {
            CCSprite *spriteA = (CCSprite *) bodyA->GetUserData();
            CCSprite *spriteB = (CCSprite *) bodyB->GetUserData();
            
            if (spriteA.tag == RIVER && spriteB.tag == PLAYER) {
                [self bumpObject:spriteB:spriteA];
            } else if (spriteA.tag == PLAYER && spriteB.tag == RIVER) {
                [self bumpObject:spriteA:spriteB];
            } else if (spriteA.tag == BRIDGE && spriteB.tag == PLAYER) {
                [self crossBridge:spriteB:spriteA];
            } else if (spriteA.tag == PLAYER && spriteB.tag == BRIDGE) {
                [self crossBridge:spriteA:spriteB];
            } else if (spriteA.tag == HOUSE && spriteB.tag == PLAYER) {
                [self visitHouse:spriteB:spriteA];
            } else if (spriteA.tag == PLAYER && spriteB.tag == HOUSE) {
                [self visitHouse:spriteA:spriteB];
            }
        }
    }
}

-(BridgeNode*)findBridge:(CCSprite*) bridge {
    for (BridgeNode *n in self.currentLevel.bridges) {
        if (n.bridge == bridge) {
            return n;
        }
    }
    
    return nil;
}

-(HouseNode*)findHouse:(CCSprite*) house {
    for (HouseNode *n in self.currentLevel.houses) {
        if (n.house == house) {
            return n;
        }
    }
    
    return nil;
}

- (void)visitHouse:(CCSprite *) player:(CCSprite*) house {
    /*
     * The player has run into a house.  We need to visit the house
     * if the player is the right color and bump it if it isn't
     */
    HouseNode *node = [self findHouse:house];
    
    if (![node isVisited]) {
        if (_player.color == node.color) {
            [node visit];
        }
    }
    
    [self bumpObject:player:house];
    
}

- (void)crossBridge:(CCSprite *) player:(CCSprite*) bridge {
    /*
     * The player has run into a bridge.  We need to cross the bridge
     * if it hasn't been crossed yet and not if it has.
     */
    BridgeNode *node = [self findBridge:bridge];
    
    if ([node isCrossed]) {
        [self bumpObject:player:bridge];
    } else {
        _inCross = true;
        [self doCross:player:node:bridge];
    }
    
}

- (void)doCross:(CCSprite *) player:(BridgeNode*) bridge:(CCSprite*) object {
    CCActionManager *mgr = [player actionManager];
    [mgr pauseTarget:player];
    
    CGPoint location;
    
    int padding = bridge.bridge.contentSize.width / 2;
    
    //     printf("player (%f, %f)\n", player.position.x, player.position.y);
    //    printf("bridge (%f, %f)\n", object.position.x, object.position.y);
    //     printf("vertical: %i\n", bridge.vertical);
    
    if (player.position.y + player.contentSize.height < object.position.y + padding) {
        // Then the player is below the bridge
        if (!bridge.vertical) {
            [self bumpObject:player:object];
        } else {
            location = ccp(player.position.x, object.position.y + object.contentSize.height + 1);
        }
    } else if (player.position.y > (object.position.y + object.contentSize.height) - padding) {
        // Then the player is above the bridge
        if (!bridge.vertical) {
            [self bumpObject:player:object];
        } else {
            location = ccp(player.position.x, (object.position.y - 1) - player.contentSize.height );
        }
    } else if (player.position.x + player.contentSize.width < object.position.x + padding) {
        // Then the player is to the right of the bridge
        if (bridge.vertical) {
            [self bumpObject:player:object];
        } else {
            location = ccp((object.position.x - 1) - player.contentSize.width, player.position.y);
        }
    } else if (player.position.x > (object.position.x + object.contentSize.width) - padding) {
        // Then the player is to the left of the bridge
        if (bridge.vertical) {
            [self bumpObject:player:object];
        } else {
            location = ccp(object.position.x + 1 + object.contentSize.width, player.position.y);
        }
    } else {
        printf("player (%f, %f)\n", player.position.x, player.position.y);
        printf("river (%f, %f)\n", object.position.x, object.position.y);
        printf("This should never happen\n");
    }
    
    [mgr removeAllActionsFromTarget:player];
    [mgr resumeTarget:player];
    
    //    printf("Moving to (%f, %f)\n", location.x, location.y);
    //    location.y += 5;
    //    _player.position = location;
    [_player.player runAction:
     [CCMoveTo actionWithDuration:0.3 position:ccp(location.x,location.y)]];
    
    [bridge cross];
    
    if (bridge.color != NONE) {
        [_player updateColor:bridge.color];
    }
    
    if ([self.currentLevel hasWon]) {
        printf("You've won");
    }
}

- (void)bumpObject:(CCSprite *) player:(CCSprite*) object {
    /*
     * The player bumped into a river or crossed bridge and is now
     * in the middle of an animation overlapping a river.  We need
     * to stop the animation and move the player back off the river
     * so they aren't overlapping anymore.
     */
    
    CCActionManager *mgr = [player actionManager];
    [mgr pauseTarget:player];
    
    int padding = object.contentSize.width / 2;
    
    /*
     * When the player collides with a river we need to move
     * the player back a little bit so they don't overlap anymore.
     */
    
    if (player.position.y + player.contentSize.height < object.position.y + padding) {
        // Then the player is below the river
        player.position = ccp(player.position.x,
                              player.position.y - 1);
    } else if (player.position.y > (object.position.y + object.contentSize.height) - padding) {
        // Then the player is above the river
        player.position = ccp(player.position.x,
                              player.position.y + 1);
    } else if (player.position.x + player.contentSize.width < object.position.x + padding) {
        // Then the player is to the right of the river
        player.position = ccp(player.position.x - 1,
                              player.position.y);
    } else if (player.position.x > (object.position.x + object.contentSize.width) - padding) {
        // Then the player is to the left of the river
        player.position = ccp(player.position.x + 1,
                              player.position.y);
    } else {
        printf("player (%f, %f)\n", player.position.x, player.position.y);
        printf("river (%f, %f)\n", object.position.x, object.position.y);
        printf("This should never happen\n");
    }
    
    [_player playerMoveEnded];
    
    [mgr removeAllActionsFromTarget:player];
    [mgr resumeTarget:player];
    
    if ([self.currentLevel hasWon]) {
        printf("You've won");
    }
    
}

- (void)spawnPlayer:(int) x: (int) y {
    
    _player = [[PlayerNode alloc] initWithTag:PLAYER:BLACK:_layerMgr];
    _player.player.position = ccp(x, y);
    
    //   CCSprite *player = [_player player];
    /*
     [_player runAction:
     [CCSequence actions:
     [CCMoveTo actionWithDuration:1.0 position:ccp(300,100)],
     [CCMoveTo actionWithDuration:1.0 position:ccp(200,200)],
     [CCMoveTo actionWithDuration:1.0 position:ccp(100,100)],
     nil]];
     */
    //    [self addChildToSheet:player];
    
}

-(bool)inObject:(CGPoint) p {
    for (BridgeNode *n in self.currentLevel.bridges) {
        if (CGRectContainsPoint([n.bridge boundingBox], p)) {
            return true;
        }
    }
    
    for (CCSprite *s in self.currentLevel.rivers) {
        if (CGRectContainsPoint([s boundingBox], p)) {
            return true;
        }
    }
    
    for (HouseNode *h in self.currentLevel.houses) {
        if (CGRectContainsPoint([h.house boundingBox], p)) {
            return true;
        }
    }
    
    return false;
    
}

-(void)ccTouchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    
    // Choose one of the touches to work with
    UITouch *touch = [touches anyObject];
    CGPoint location = [touch locationInView:[touch view]];
    location = [[CCDirector sharedDirector] convertToGL:location];
    
    if (_player == nil) {
        if (![self inObject:location]) {
            [self spawnPlayer:location.x: location.y];
        }
    } else {
        _inCross = false;
        
        [_player moveTo:location];
//        [_player.player runAction:
//         [CCMoveTo actionWithDuration:distance/velocity position:ccp(location.x,location.y)]];
    }
    
}

-(CGSize)winSizeTiles {
    CGSize winSize = [self getWinSize];
    return CGSizeMake(winSize.width / _layerMgr.tileSize.width,
                      winSize.height / _layerMgr.tileSize.height);
}

-(CGPoint)tileToPoint:(int) x: (int)y {
    printf("tileToPoint (%i, %i)\n", x, y);
    printf("tileSize (%f, %f)\n", _layerMgr.tileSize.width, _layerMgr.tileSize.height);
    return CGPointMake(x * _layerMgr.tileSize.width,
                       y * _layerMgr.tileSize.height);
}

-(CGSize)getWinSize {
    //CGRect r = [[UIScreen mainScreen] bounds];
    //return r.size;
    return [[CCDirector sharedDirector] winSize];
}

-(void)dealloc {
    
    delete _world;
    delete _debugDraw;
    
    delete _contactListener;
    [_spriteSheet release];
    [_player dealloc];
    
    [_currentLevelPath release];
    _currentLevelPath = nil;
    
    [self.currentLevel dealloc];
    
    [super dealloc];
}

@end